defmodule JidoManagedAgents.Sessions.RuntimeToolsTest do
  use ExUnit.Case, async: false

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions.RuntimeTools
  alias JidoManagedAgents.Sessions.RuntimeWorkspace
  alias JidoManagedAgents.Sessions.Workspace
  alias Req.Test

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_runtime_tools =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.RuntimeTools)

    on_exit(fn ->
      Process.delete(:runtime_tools_web_search_response)

      if previous_runtime_tools == nil do
        Application.delete_env(:jido_managed_agents, JidoManagedAgents.Sessions.RuntimeTools)
      else
        Application.put_env(
          :jido_managed_agents,
          JidoManagedAgents.Sessions.RuntimeTools,
          previous_runtime_tools
        )
      end
    end)

    :ok
  end

  test "tool_definitions/1 honors built-in enablement rules" do
    agent_version =
      struct!(AgentVersion, %{
        tools: [
          %{
            "type" => "agent_toolset_20260401",
            "default_config" => %{"enabled" => false, "permission_policy" => "always_allow"},
            "configs" => %{
              "read" => %{"enabled" => true},
              "write" => %{"enabled" => true}
            }
          }
        ]
      })

    assert agent_version
           |> RuntimeTools.tool_definitions()
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["read", "write"]
  end

  test "tool_definitions/1 can disable web_fetch and web_search through built-in configs" do
    agent_version =
      struct!(AgentVersion, %{
        tools: [
          %{
            "type" => "agent_toolset_20260401",
            "configs" => %{
              "web_fetch" => %{"enabled" => false},
              "web_search" => %{"enabled" => false}
            }
          }
        ]
      })

    names =
      agent_version
      |> RuntimeTools.tool_definitions()
      |> Enum.map(& &1.name)

    refute "web_fetch" in names
    refute "web_search" in names
    assert "read" in names
  end

  test "tool_definitions/1 includes agent-defined custom tools" do
    agent_version =
      struct!(AgentVersion, %{
        tools: [
          %{
            "type" => "custom",
            "name" => "lookup_release",
            "description" => "Look up release metadata from the host application.",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "package" => %{"type" => "string"}
              },
              "required" => ["package"]
            },
            "permission_policy" => "always_allow"
          }
        ]
      })

    [tool] = RuntimeTools.tool_definitions(agent_version)

    assert tool.name == "lookup_release"
    assert RuntimeTools.permission_policy(agent_version, "lookup_release") == "always_allow"
  end

  test "bash_policy/1 keeps command limits explicit and normalizes overrides" do
    assert RuntimeTools.bash_policy(%{"timeout_ms" => "25", "max_output_bytes" => 128}) == %{
             "timeout_ms" => 25,
             "max_output_bytes" => 128,
             "failure_exit_status" => 1,
             "timeout_exit_status" => 124,
             "cancelled_exit_status" => 130,
             "crashed_exit_status" => 137
           }
  end

  test "execute/2 runs read, write, edit, glob, and grep with structured results" do
    workspace = build_workspace(:memory_vfs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:ok, write_result, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_write",
               "name" => "write",
               "arguments" => %{
                 "path" => "/notes/hello.txt",
                 "content" => "Hello, Workspace!"
               }
             })

    assert write_result["ok"]
    assert write_result["result"]["bytes_written"] == 17

    assert {:ok, read_result, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               id: "toolu_read",
               name: "read",
               arguments: %{"path" => "/notes/hello.txt"}
             })

    assert read_result["result"]["content"] == "Hello, Workspace!"

    assert {:ok, edit_result, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_edit",
               "name" => "edit",
               "arguments" => %{
                 "path" => "/notes/hello.txt",
                 "old_text" => "Hello",
                 "new_text" => "Hi"
               }
             })

    assert edit_result["result"]["replacements"] == 1

    assert {:ok, glob_result, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_glob",
               "name" => "glob",
               "arguments" => %{"pattern" => "/**/*.txt"}
             })

    assert glob_result["result"]["matches"] == ["/notes/hello.txt"]

    assert {:ok, grep_result, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_grep",
               "name" => "grep",
               "arguments" => %{"pattern" => "Workspace", "path" => "/notes"}
             })

    assert grep_result["result"]["matches"] == [
             %{
               "path" => "/notes/hello.txt",
               "line_number" => 1,
               "line" => "Hi, Workspace!"
             }
           ]

    assert {:ok, "Hi, Workspace!"} = RuntimeWorkspace.read(runtime_workspace, "/notes/hello.txt")
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/2 returns structured errors for invalid inputs and missing files" do
    workspace = build_workspace(:memory_vfs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:error, read_error, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_missing",
               "name" => "read",
               "arguments" => %{"path" => "/missing.txt"}
             })

    assert read_error["ok"] == false
    assert read_error["error"]["error_type"] == "file_not_found"

    assert {:error, edit_error, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_bad_edit",
               "name" => "edit",
               "arguments" => %{
                 "path" => "/missing.txt",
                 "old_text" => "",
                 "new_text" => "replacement"
               }
             })

    assert edit_error["ok"] == false
    assert edit_error["error"]["error_type"] in ["invalid_edit", "file_not_found"]

    assert {:error, invalid_input_error, runtime_workspace} =
             RuntimeTools.execute(runtime_workspace, %{
               "id" => "toolu_invalid",
               "name" => "write",
               "arguments" => %{"path" => "/missing.txt"}
             })

    assert invalid_input_error["error"]["error_type"] == "invalid_input"
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 runs bash commands with captured output and explicit exit status" do
    workspace = build_workspace(:memory_vfs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:ok, runtime_workspace} =
             RuntimeWorkspace.write(runtime_workspace, "/notes/hello.txt", "Hi!")

    assert {:ok, bash_result, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_bash_success",
                 "name" => "bash",
                 "arguments" => %{"command" => "pwd && cat /notes/hello.txt"}
               }
             )

    assert bash_result["ok"] == true

    assert bash_result["result"] == %{
             "output" => "/\nHi!",
             "exit_status" => 0
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 surfaces bash command failures with captured partial output" do
    workspace = build_workspace(:memory_vfs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:error, bash_error, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_bash_failure",
                 "name" => "bash",
                 "arguments" => %{"command" => "echo before && cat /missing.txt"}
               }
             )

    assert bash_error["ok"] == false

    assert bash_error["error"] == %{
             "error_type" => "file_not_found",
             "message" => "not_found: /missing.txt (exit status 1)",
             "output" => "before\n",
             "exit_status" => 1
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 times out bash commands according to the visible runtime policy" do
    workspace = build_workspace(:memory_vfs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:error, bash_error, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_bash_timeout",
                 "name" => "bash",
                 "arguments" => %{"command" => "sleep 1"}
               },
               bash_policy: %{"timeout_ms" => 10}
             )

    assert bash_error["ok"] == false
    assert bash_error["error"]["error_type"] == "command_timeout"
    assert bash_error["error"]["exit_status"] == 124
    assert bash_error["error"]["message"] == "Command timed out with exit status 124."
    assert is_binary(bash_error["error"]["output"])
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 keeps bash commands isolated to the workspace root" do
    root =
      Path.join(System.tmp_dir!(), "runtime-tools-bash-#{System.unique_integer([:positive])}")

    outside_path =
      Path.join(
        System.tmp_dir!(),
        "runtime-tools-bash-outside-#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside_path)
    end)

    File.mkdir_p!(root)
    File.write!(outside_path, "top-secret")

    workspace = build_workspace(:local_vfs, %{config: %{"root" => root}})

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)
    assert {:ok, runtime_workspace} = RuntimeWorkspace.mkdir(runtime_workspace, "/nested")

    assert {:error, bash_error, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_bash_isolation",
                 "name" => "bash",
                 "arguments" => %{
                   "command" =>
                     "cd /nested && echo workspace-only && cat ../../#{Path.basename(outside_path)}"
                 }
               }
             )

    assert bash_error["error"]["error_type"] == "file_not_found"
    assert bash_error["error"]["exit_status"] == 1
    assert bash_error["error"]["output"] == "workspace-only\n"
    refute bash_error["error"]["output"] =~ "top-secret"
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 runs web_fetch with normalized page content from Req" do
    workspace = build_workspace(:memory_vfs)
    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    Test.stub(__MODULE__.WebFetchStub, fn conn ->
      Test.html(
        conn,
        """
        <html>
          <head>
            <title>Example Domain</title>
            <meta name="description" content="A compact example page." />
          </head>
          <body>
            <main>
              <h1>Example Domain</h1>
              <p>This domain is for use in examples.</p>
            </main>
          </body>
        </html>
        """
      )
    end)

    assert {:ok, result, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_web_fetch",
                 "name" => "web_fetch",
                 "arguments" => %{"url" => "https://example.com"}
               },
               web_fetch_req_options: [plug: {Req.Test, __MODULE__.WebFetchStub}]
             )

    assert result["ok"] == true
    assert result["result"]["url"] == "https://example.com"
    assert result["result"]["status"] == 200
    assert result["result"]["title"] == "Example Domain"
    assert result["result"]["description"] == "A compact example page."
    assert result["result"]["content_type"] == "text/html; charset=utf-8"
    assert result["result"]["text"] =~ "Example Domain"
    assert result["result"]["text"] =~ "This domain is for use in examples."
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 returns structured network failures for web_fetch" do
    workspace = build_workspace(:memory_vfs)
    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    Test.stub(__MODULE__.WebFetchFailureStub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, result, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_web_fetch_timeout",
                 "name" => "web_fetch",
                 "arguments" => %{"url" => "https://example.com/slow"}
               },
               web_fetch_req_options: [plug: {Req.Test, __MODULE__.WebFetchFailureStub}]
             )

    assert result["ok"] == false
    assert result["error"]["error_type"] == "network_timeout"
    assert result["error"]["message"] == "timeout"
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 runs web_search through a deterministic adapter" do
    workspace = build_workspace(:memory_vfs)
    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    Process.put(
      :runtime_tools_web_search_response,
      {:ok,
       [
         %{
           title: "Elixir",
           url: "https://elixir-lang.org",
           snippet: "Elixir is a dynamic, functional language."
         },
         %{
           title: "Phoenix Framework",
           url: "https://www.phoenixframework.org",
           snippet: "Productive web development."
         }
       ]}
    )

    assert {:ok, result, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_web_search",
                 "name" => "web_search",
                 "arguments" => %{"query" => "elixir phoenix", "max_results" => 1}
               },
               web_search_adapter: __MODULE__.StubSearchAdapter
             )

    assert_received {:stub_web_search_called, "elixir phoenix", adapter_opts}
    assert adapter_opts[:limit] == 1
    assert result["ok"] == true

    assert result["result"] == %{
             "query" => "elixir phoenix",
             "results" => [
               %{
                 "title" => "Elixir",
                 "url" => "https://elixir-lang.org",
                 "snippet" => "Elixir is a dynamic, functional language."
               }
             ]
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "execute/3 surfaces deterministic adapter failures for web_search" do
    workspace = build_workspace(:memory_vfs)
    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    Process.put(
      :runtime_tools_web_search_response,
      {:error, %{"error_type" => "network_error", "message" => "connection refused"}}
    )

    assert {:error, result, runtime_workspace} =
             RuntimeTools.execute(
               runtime_workspace,
               %{
                 "id" => "toolu_web_search_failure",
                 "name" => "web_search",
                 "arguments" => %{"query" => "elixir"}
               },
               web_search_adapter: __MODULE__.StubSearchAdapter
             )

    assert result["ok"] == false
    assert result["error"]["error_type"] == "network_error"
    assert result["error"]["message"] == "connection refused"
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  defp build_workspace(backend, attrs \\ %{}) do
    attrs = Map.new(attrs)

    struct!(Workspace, %{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      name: Map.get(attrs, :name, "workspace-#{System.unique_integer([:positive])}"),
      backend: backend,
      config: Map.get(attrs, :config, %{}),
      state: Map.get(attrs, :state, "ready"),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defmodule StubSearchAdapter do
    @behaviour JidoManagedAgents.Sessions.RuntimeWeb.SearchAdapter

    @impl true
    def search(query, opts) do
      send(self(), {:stub_web_search_called, query, opts})

      case Process.get(:runtime_tools_web_search_response) do
        nil -> {:ok, []}
        response -> response
      end
    end
  end
end
