defmodule JidoManagedAgents.Sessions.SessionRuntimeTurnTest do
  use ExUnit.Case, async: false

  alias Jido.Agent.Directive
  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions.RuntimeWorkspace
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.SessionEvent
  alias JidoManagedAgents.Sessions.SessionRuntime
  alias JidoManagedAgents.Sessions.Workspace
  alias Plug.Conn

  setup do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_api_key = Application.get_env(:req_llm, :anthropic_api_key)

    on_exit(fn ->
      if previous_runtime == nil do
        Application.delete_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)
      else
        Application.put_env(
          :jido_managed_agents,
          JidoManagedAgents.Sessions.SessionRuntime,
          previous_runtime
        )
      end

      if previous_api_key == nil do
        Application.delete_env(:req_llm, :anthropic_api_key)
      else
        Application.put_env(:req_llm, :anthropic_api_key, previous_api_key)
      end
    end)

    :ok
  end

  test "build_turn_activity/3 orders thinking, tool_use, tool_result, and final message directives" do
    configure_runtime_inference!(
      tool_flow_plug(
        "Create a note in the workspace",
        [
          %{
            "id" => "toolu_write_turn",
            "name" => "write",
            "input" => %{
              "path" => "/notes/todo.txt",
              "content" => "Remember the tests"
            }
          },
          %{
            "id" => "toolu_read_turn",
            "name" => "read",
            "input" => %{"path" => "/notes/todo.txt"}
          }
        ],
        "Created the note and checked its contents."
      )
    )

    {session, event, runtime_workspace} = build_runtime_fixture()

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == [
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message"
           ]

    assert directive_payload(Enum.at(directives, 1))["input"] == %{
             "path" => "/notes/todo.txt",
             "content" => "Remember the tests"
           }

    assert directive_payload(Enum.at(directives, 2))["result"] == %{
             "path" => "/notes/todo.txt",
             "bytes_written" => 18
           }

    assert directive_payload(Enum.at(directives, 4))["result"] == %{
             "path" => "/notes/todo.txt",
             "content" => "Remember the tests"
           }

    assert directive_payload(Enum.at(directives, 5))["content"] == [
             %{
               "type" => "text",
               "text" => "Created the note and checked its contents."
             }
           ]

    assert {:ok, "Remember the tests"} =
             RuntimeWorkspace.read(runtime_workspace, "/notes/todo.txt")

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "build_turn_activity/3 emits structured tool_result payloads for tool failures" do
    configure_runtime_inference!(
      tool_flow_plug(
        "Read a missing file",
        [
          %{
            "id" => "toolu_missing_turn",
            "name" => "read",
            "input" => %{"path" => "/missing.txt"}
          }
        ],
        "The file does not exist."
      )
    )

    {session, event, runtime_workspace} = build_runtime_fixture("Read a missing file")

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == [
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message"
           ]

    assert directive_payload(Enum.at(directives, 2))["ok"] == false

    assert directive_payload(Enum.at(directives, 2))["error"] == %{
             "error_type" => "file_not_found",
             "message" => "file_not_found"
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "build_turn_activity/3 emits bash tool directives with explicit exit status" do
    configure_runtime_inference!(
      tool_flow_plug(
        "Inspect the workspace shell",
        [
          %{
            "id" => "toolu_bash_turn",
            "name" => "bash",
            "input" => %{"command" => "pwd && echo ready"}
          }
        ],
        "Verified the shell command output."
      )
    )

    {session, event, runtime_workspace} = build_runtime_fixture("Inspect the workspace shell")

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == [
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message"
           ]

    assert directive_payload(Enum.at(directives, 1))["tool_name"] == "bash"

    assert directive_payload(Enum.at(directives, 1))["input"] == %{
             "command" => "pwd && echo ready"
           }

    assert directive_payload(Enum.at(directives, 2))["result"] == %{
             "output" => "/\nready\n",
             "exit_status" => 0
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "build_turn_activity/3 emits blocking custom tool use directives" do
    configure_runtime_inference!(
      custom_tool_pause_plug(
        "Fetch the release metadata",
        [
          %{
            "id" => "toolu_custom_release",
            "name" => "lookup_release",
            "input" => %{"package" => "jido_managed_agents"}
          }
        ]
      )
    )

    {session, event, runtime_workspace} =
      build_runtime_fixture(
        "Fetch the release metadata",
        [
          %{
            "type" => "custom",
            "name" => "lookup_release",
            "description" => "Look up package release metadata from the host application.",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"package" => %{"type" => "string"}},
              "required" => ["package"]
            },
            "permission_policy" => "always_allow"
          }
        ]
      )

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == [
             "agent.thinking",
             "agent.custom_tool_use"
           ]

    assert directive_payload(Enum.at(directives, 1))["tool_name"] == "lookup_release"

    assert directive_payload(Enum.at(directives, 1))["input"] == %{
             "package" => "jido_managed_agents"
           }

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  defp build_runtime_fixture(
         prompt \\ "Create a note in the workspace",
         tools \\ [always_allow_builtin_toolset()]
       ) do
    workspace =
      struct!(Workspace, %{
        id: Ecto.UUID.generate(),
        name: "workspace-#{System.unique_integer([:positive])}",
        backend: :memory_vfs,
        config: %{},
        state: "ready",
        metadata: %{}
      })

    session =
      struct!(Session, %{
        id: Ecto.UUID.generate(),
        agent_version:
          struct!(AgentVersion, %{
            model: %{"id" => "claude-sonnet-4-6"},
            system: "Stay precise.",
            tools: tools,
            agent_version_skills: []
          })
      })

    event =
      struct!(SessionEvent, %{
        id: Ecto.UUID.generate(),
        sequence: 1,
        type: "user.message",
        content: [%{"type" => "text", "text" => prompt}],
        payload: %{}
      })

    {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)
    {session, event, runtime_workspace}
  end

  defp configure_runtime_inference!(plug) do
    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.SessionRuntime,
      anthropic_compatible_provider: :anthropic,
      max_tokens: 1024,
      temperature: 0.2,
      timeout: 30_000,
      req_http_options: [plug: plug]
    )
  end

  defp tool_flow_plug(expected_prompt, tool_calls, final_reply_text) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, fn count -> {count, count + 1} end)

      assert params["model"] == "claude-sonnet-4-6"
      assert params["system"] == "Stay precise."

      assert Enum.map(params["tools"], & &1["name"]) == [
               "bash",
               "edit",
               "glob",
               "grep",
               "read",
               "web_fetch",
               "web_search",
               "write"
             ]

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_turn_tools_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" =>
                Enum.map(tool_calls, fn tool_call ->
                  %{
                    "type" => "tool_use",
                    "id" => tool_call["id"],
                    "name" => tool_call["name"],
                    "input" => tool_call["input"]
                  }
                end),
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          encoded_request = Jason.encode!(params)

          Enum.each(tool_calls, fn tool_call ->
            assert encoded_request =~ tool_call["id"]
          end)

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_turn_tools_2",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => final_reply_text}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 24, "output_tokens" => 9}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp custom_tool_pause_plug(expected_prompt, tool_calls) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, fn count -> {count, count + 1} end)

      assert params["model"] == "claude-sonnet-4-6"
      assert params["system"] == "Stay precise."
      assert Enum.map(params["tools"], & &1["name"]) == ["lookup_release"]

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_turn_custom_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" =>
                Enum.map(tool_calls, fn tool_call ->
                  %{
                    "type" => "tool_use",
                    "id" => tool_call["id"],
                    "name" => tool_call["name"],
                    "input" => tool_call["input"]
                  }
                end),
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 12, "output_tokens" => 6}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp directive_type(%Directive.Emit{signal: signal}), do: signal.type
  defp directive_payload(%Directive.Emit{signal: signal}), do: signal.data

  defp normalized_prompt(params) do
    get_in(params, ["messages", Access.at(0), "content"]) ||
      get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"])
  end

  defp always_allow_builtin_toolset do
    %{
      "type" => "agent_toolset_20260401",
      "default_config" => %{"permission_policy" => "always_allow"}
    }
  end
end
