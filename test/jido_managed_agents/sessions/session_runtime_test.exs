defmodule JidoManagedAgents.Sessions.SessionRuntimeTest do
  use JidoManagedAgents.DataCase, async: false

  alias JidoManagedAgents.Sessions.RuntimeWorkspace
  alias JidoManagedAgents.Sessions.SessionEventLog
  alias JidoManagedAgents.Sessions.SessionRuntime
  alias JidoManagedAgents.Sessions.WorkspaceBackend.LocalVFS
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers
  alias Plug.Conn
  alias Req.Test

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_runtime_tools =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.RuntimeTools)

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

      if previous_runtime_tools == nil do
        Application.delete_env(:jido_managed_agents, JidoManagedAgents.Sessions.RuntimeTools)
      else
        Application.put_env(
          :jido_managed_agents,
          JidoManagedAgents.Sessions.RuntimeTools,
          previous_runtime_tools
        )
      end

      Process.delete(:session_runtime_web_search_response)

      if previous_api_key == nil do
        Application.delete_env(:req_llm, :anthropic_api_key)
      else
        Application.put_env(:req_llm, :anthropic_api_key, previous_api_key)
      end
    end)

    :ok
  end

  test "run/2 consumes a persisted user message through provider-backed inference and persists Jido activity" do
    configure_runtime_inference!(
      success_anthropic_plug("Plan the next step", "Provider-backed plan for the next step")
    )

    owner = Helpers.create_user!()
    agent = Helpers.create_agent!(owner, %{name: "runtime-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Plan the next step"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)

    assert result.session.status == :idle
    assert result.session.last_processed_event_index == user_event.sequence
    assert Enum.map(result.consumed_events, & &1.sequence) == [user_event.sequence]
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "agent.message"]
    assert Enum.all?(result.emitted_events, &match?(%DateTime{}, &1.processed_at))
    assert RuntimeWorkspace.workspace_id(result.runtime_workspace) == workspace.id

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    [
      idle_event,
      processed_user_event,
      running_event,
      thinking_event,
      message_event,
      final_idle_event
    ] =
      loaded_session.events

    assert {idle_event.sequence, idle_event.type} == {0, "session.status_idle"}
    assert {processed_user_event.sequence, processed_user_event.type} == {1, "user.message"}
    assert match?(%DateTime{}, processed_user_event.processed_at)
    assert {running_event.sequence, running_event.type} == {2, "session.status_running"}
    assert {thinking_event.sequence, thinking_event.type} == {3, "agent.thinking"}
    assert {message_event.sequence, message_event.type} == {4, "agent.message"}
    assert {final_idle_event.sequence, final_idle_event.type} == {5, "session.status_idle"}

    assert thinking_event.metadata["jido_signal"]["source"] == "/sessions/runtime"
    assert message_event.payload["trigger_event_id"] == user_event.id
    assert message_event.payload["workspace_id"] == workspace.id
    assert message_event.payload["provider"] == "anthropic"
    assert message_event.payload["model"] == "claude-sonnet-4-6"

    assert message_event.payload["usage"] == %{
             "cached_tokens" => 0,
             "input_tokens" => 12,
             "output_tokens" => 18,
             "reasoning_tokens" => 0,
             "total_tokens" => 30
           }

    assert message_event.content == [
             %{
               "type" => "text",
               "text" => "Provider-backed plan for the next step"
             }
           ]
  end

  test "run/2 resolves the local_vfs workspace through RuntimeWorkspace and persists idle/running transitions" do
    configure_runtime_inference!(
      success_anthropic_plug("Open the attached workspace", "Opened the attached workspace.")
    )

    owner = Helpers.create_user!()
    agent = Helpers.create_agent!(owner, %{name: "local-runtime-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)

    root =
      Path.join(System.tmp_dir!(), "session-runtime-local-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(root)
    end)

    workspace =
      Helpers.create_workspace!(owner, agent, %{
        backend: :local_vfs,
        config: %{"root" => root}
      })

    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Open the attached workspace"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert RuntimeWorkspace.backend(result.runtime_workspace) == LocalVFS
    assert RuntimeWorkspace.persisted_workspace(result.runtime_workspace).id == workspace.id
    assert RuntimeWorkspace.workspace_id(result.runtime_workspace) == workspace.id
    assert File.dir?(root)

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.message",
             "session.status_idle"
           ]

    assert Enum.at(loaded_session.events, 2).payload == %{"status" => "running"}
    assert Enum.at(loaded_session.events, 5).payload == %{"status" => "idle"}
  end

  test "run/2 delegates to callable agents with persisted session threads and isolated thread events" do
    owner =
      Helpers.create_user!(%{
        email: "runtime-delegation-#{System.unique_integer([:positive])}@example.com"
      })

    delegate_agent = Helpers.create_agent!(owner, %{name: "delegate-reviewer"})
    delegate_version = Helpers.latest_agent_version!(owner, delegate_agent)

    root_agent =
      Helpers.create_agent!(owner, %{name: "delegate-coordinator", with_version: false})

    root_version =
      Helpers.create_agent_version!(owner, root_agent, %{
        version: 1,
        agent_version_callable_agents: [
          callable_agent_link(owner, delegate_agent, delegate_version.id, 0)
        ]
      })

    configure_runtime_inference!(
      delegation_plug(
        "Coordinate the migration review",
        delegate_tool_name(delegate_agent.id),
        "Review the migration carefully.",
        "Migration reviewed.",
        "Coordinator summary."
      )
    )

    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, root_agent)
    session = Helpers.create_session!(owner, root_agent, root_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Coordinate the migration review"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle

    loaded_session =
      Helpers.get_session!(owner, session.id, [:events, threads: [:events, :agent_version]])

    primary_thread = Enum.find(loaded_session.threads, &(&1.role == :primary))
    delegate_thread = Enum.find(loaded_session.threads, &(&1.role == :delegate))

    assert primary_thread
    assert delegate_thread
    assert delegate_thread.parent_thread_id == primary_thread.id
    assert delegate_thread.agent_id == delegate_agent.id
    assert delegate_thread.agent_version.version == 1

    assert Enum.map(delegate_thread.events, & &1.type) == [
             "agent.thread_message_received",
             "agent.thinking",
             "agent.message",
             "agent.thread_message_sent"
           ]

    assert Enum.map(result.emitted_events, & &1.type) == [
             "agent.thinking",
             "session.thread_created",
             "agent.thread_message_sent",
             "agent.thread_message_received",
             "session.thread_idle",
             "agent.message"
           ]

    assert Enum.any?(loaded_session.events, &(&1.type == "session.thread_created"))
    assert Enum.any?(loaded_session.events, &(&1.type == "agent.thread_message_sent"))
    assert Enum.any?(loaded_session.events, &(&1.type == "agent.thread_message_received"))
    assert Enum.any?(loaded_session.events, &(&1.session_thread_id == delegate_thread.id))
  end

  test "run/2 rejects nested callable-agent delegation after one level" do
    owner =
      Helpers.create_user!(%{
        email: "runtime-nested-delegation-#{System.unique_integer([:positive])}@example.com"
      })

    leaf_agent = Helpers.create_agent!(owner, %{name: "delegate-leaf"})
    delegate_agent = Helpers.create_agent!(owner, %{name: "delegate-middle", with_version: false})

    delegate_version =
      Helpers.create_agent_version!(owner, delegate_agent, %{
        version: 1,
        agent_version_callable_agents: [
          callable_agent_link(
            owner,
            leaf_agent,
            Helpers.latest_agent_version!(owner, leaf_agent).id,
            0
          )
        ]
      })

    root_agent = Helpers.create_agent!(owner, %{name: "delegate-root", with_version: false})

    root_version =
      Helpers.create_agent_version!(owner, root_agent, %{
        version: 1,
        agent_version_callable_agents: [
          callable_agent_link(owner, delegate_agent, delegate_version.id, 0)
        ]
      })

    configure_runtime_inference!(
      nested_delegation_plug(
        "Delegate once",
        delegate_tool_name(delegate_agent.id),
        "Push this downward.",
        delegate_tool_name(leaf_agent.id)
      )
    )

    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, root_agent)
    session = Helpers.create_session!(owner, root_agent, root_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Delegate once"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle
    assert Enum.any?(result.emitted_events, &(&1.type == "session.error"))

    loaded_session = Helpers.get_session!(owner, session.id, [:events, threads: [:events]])
    primary_thread = Enum.find(loaded_session.threads, &(&1.role == :primary))
    delegate_thread = Enum.find(loaded_session.threads, &(&1.role == :delegate))

    assert primary_thread
    assert delegate_thread

    assert Enum.any?(delegate_thread.events, fn event ->
             event.type == "session.error" and
               event.payload["error_type"] == "nested_delegation_not_allowed"
           end)

    assert Enum.any?(loaded_session.events, fn event ->
             event.type == "session.error" and
               event.session_thread_id == primary_thread.id and
               event.payload["error_type"] == "nested_delegation_not_allowed"
           end)
  end

  test "run/2 persists provider failures as session.error events for ReqLLM-native model specs" do
    configure_runtime_inference!(provider_failure_plug())

    owner = Helpers.create_user!()

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-provider-error-agent",
        model: %{
          "provider" => "anthropic",
          "id" => "claude-haiku-4-5",
          "base_url" => "https://req-llm-provider.test"
        }
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Handle the provider failure"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)

    assert result.session.status == :idle
    assert result.session.last_processed_event_index == user_event.sequence
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    [
      _idle_event,
      processed_user_event,
      _running_event,
      _thinking_event,
      error_event,
      final_idle_event
    ] = loaded_session.events

    assert processed_user_event.sequence == user_event.sequence
    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "provider_error"
    assert error_event.payload["provider"] == "anthropic"
    assert error_event.payload["model"] == "anthropic:claude-haiku-4-5"
    assert error_event.payload["message"] =~ "provider unavailable"
    assert error_event.payload["workspace_id"] == workspace.id
    assert final_idle_event.type == "session.status_idle"
  end

  test "run/2 executes built-in filesystem tools and persists tool events before their results" do
    configure_runtime_inference!(
      filesystem_tool_plug(
        "Create a note in the workspace",
        [
          %{
            "id" => "toolu_write_note",
            "name" => "write",
            "input" => %{
              "path" => "/notes/todo.txt",
              "content" => "Remember the tests"
            }
          },
          %{
            "id" => "toolu_read_note",
            "name" => "read",
            "input" => %{"path" => "/notes/todo.txt"}
          }
        ],
        "Created /notes/todo.txt and verified the contents."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-tools-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-tools-agent",
        tools: [always_allow_builtin_toolset()]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Create a note in the workspace"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.last_processed_event_index == user_event.sequence

    assert {:ok, "Remember the tests"} =
             RuntimeWorkspace.read(result.runtime_workspace, "/notes/todo.txt")

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message",
             "session.status_idle"
           ]

    write_use_event = Enum.at(loaded_session.events, 4)
    write_result_event = Enum.at(loaded_session.events, 5)
    read_use_event = Enum.at(loaded_session.events, 6)
    read_result_event = Enum.at(loaded_session.events, 7)
    message_event = Enum.at(loaded_session.events, 8)

    assert write_use_event.payload["tool_use_id"] == "toolu_write_note"
    assert write_use_event.payload["tool_name"] == "write"

    assert write_use_event.payload["input"] == %{
             "path" => "/notes/todo.txt",
             "content" => "Remember the tests"
           }

    assert write_result_event.payload["tool_use_id"] == "toolu_write_note"
    assert write_result_event.payload["ok"] == true

    assert write_result_event.payload["result"] == %{
             "path" => "/notes/todo.txt",
             "bytes_written" => 18
           }

    assert read_use_event.payload["tool_name"] == "read"

    assert read_result_event.payload["result"] == %{
             "path" => "/notes/todo.txt",
             "content" => "Remember the tests"
           }

    assert message_event.content == [
             %{
               "type" => "text",
               "text" => "Created /notes/todo.txt and verified the contents."
             }
           ]
  end

  test "run/2 executes bash tool calls and persists Anthropic-style tool events" do
    configure_runtime_inference!(
      filesystem_tool_plug(
        "Inspect the workspace shell",
        [
          %{
            "id" => "toolu_bash_workspace",
            "name" => "bash",
            "input" => %{"command" => "pwd && echo ready"}
          }
        ],
        "Verified the shell command output."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-bash-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-bash-agent",
        tools: [always_allow_builtin_toolset()]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Inspect the workspace shell"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message",
             "session.status_idle"
           ]

    tool_use_event = Enum.at(loaded_session.events, 4)
    tool_result_event = Enum.at(loaded_session.events, 5)

    assert tool_use_event.payload["tool_name"] == "bash"
    assert tool_use_event.payload["input"] == %{"command" => "pwd && echo ready"}

    assert tool_result_event.payload["tool_name"] == "bash"
    assert tool_result_event.payload["ok"] == true

    assert tool_result_event.payload["result"] == %{
             "output" => "/\nready\n",
             "exit_status" => 0
           }
  end

  test "run/2 executes web_fetch tool calls and persists Anthropic-style tool events" do
    configure_runtime_inference!(
      filesystem_tool_plug(
        "Fetch the example page",
        [
          %{
            "id" => "toolu_web_fetch_page",
            "name" => "web_fetch",
            "input" => %{"url" => "https://example.com"}
          }
        ],
        "Fetched the example page."
      )
    )

    Test.stub(__MODULE__.WebFetchSessionStub, fn conn ->
      Test.html(
        conn,
        """
        <html>
          <head><title>Example Domain</title></head>
          <body><main><p>Example content for tool testing.</p></main></body>
        </html>
        """
      )
    end)

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.RuntimeTools,
      web_fetch_req_options: [plug: {Req.Test, __MODULE__.WebFetchSessionStub}]
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-web-fetch-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-web-fetch-agent",
        tools: [always_allow_builtin_toolset()]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Fetch the example page"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    tool_use_event = Enum.at(loaded_session.events, 4)
    tool_result_event = Enum.at(loaded_session.events, 5)

    assert tool_use_event.type == "agent.tool_use"
    assert tool_use_event.payload["tool_name"] == "web_fetch"
    assert tool_use_event.payload["input"] == %{"url" => "https://example.com"}

    assert tool_result_event.type == "agent.tool_result"
    assert tool_result_event.payload["tool_name"] == "web_fetch"
    assert tool_result_event.payload["ok"] == true
    assert tool_result_event.payload["result"]["title"] == "Example Domain"
    assert tool_result_event.payload["result"]["text"] =~ "Example content for tool testing."
  end

  test "run/2 executes web_search tool calls and persists Anthropic-style tool events" do
    configure_runtime_inference!(
      filesystem_tool_plug(
        "Search the web for Phoenix",
        [
          %{
            "id" => "toolu_web_search_page",
            "name" => "web_search",
            "input" => %{"query" => "phoenix liveview"}
          }
        ],
        "Searched the web for Phoenix."
      )
    )

    Process.put(
      :session_runtime_web_search_response,
      {:ok,
       [
         %{
           title: "Phoenix LiveView",
           url: "https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html",
           snippet: "Rich, real-time user experiences with server-rendered HTML."
         }
       ]}
    )

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.RuntimeTools,
      web_search_adapter: __MODULE__.StubSearchAdapter
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-web-search-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-web-search-agent",
        tools: [always_allow_builtin_toolset()]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Search the web for Phoenix"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle
    assert_received {:stub_session_web_search_called, "phoenix liveview", adapter_opts}
    assert adapter_opts[:limit] == 5

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    tool_use_event = Enum.at(loaded_session.events, 4)
    tool_result_event = Enum.at(loaded_session.events, 5)

    assert tool_use_event.type == "agent.tool_use"
    assert tool_use_event.payload["tool_name"] == "web_search"
    assert tool_use_event.payload["input"] == %{"query" => "phoenix liveview"}

    assert tool_result_event.type == "agent.tool_result"
    assert tool_result_event.payload["tool_name"] == "web_search"
    assert tool_result_event.payload["ok"] == true

    assert tool_result_event.payload["result"] == %{
             "query" => "phoenix liveview",
             "results" => [
               %{
                 "title" => "Phoenix LiveView",
                 "url" => "https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html",
                 "snippet" => "Rich, real-time user experiences with server-rendered HTML."
               }
             ]
           }
  end

  test "run/2 surfaces tool execution failures as structured agent.tool_result events" do
    configure_runtime_inference!(
      filesystem_tool_plug(
        "Read a missing file",
        [
          %{
            "id" => "toolu_missing_file",
            "name" => "read",
            "input" => %{"path" => "/missing.txt"}
          }
        ],
        "The file does not exist in the workspace."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-tool-errors-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-tool-error-agent",
        tools: [always_allow_builtin_toolset()]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Read a missing file"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.tool_use",
             "agent.tool_result",
             "agent.message",
             "session.status_idle"
           ]

    tool_result_event = Enum.at(loaded_session.events, 5)

    assert tool_result_event.payload["tool_name"] == "read"
    assert tool_result_event.payload["ok"] == false
    assert tool_result_event.payload["error"]["error_type"] == "file_not_found"
    assert tool_result_event.payload["error"]["message"] == "file_not_found"
    assert Enum.at(loaded_session.events, 6).type == "agent.message"
  end

  test "run/2 pauses before always_ask tools and records requires_action stop reasons" do
    tool_call = %{
      "id" => "toolu_pause_bash",
      "name" => "bash",
      "input" => %{"command" => "pwd && echo awaiting approval"}
    }

    configure_runtime_inference!(approval_pause_plug("Inspect the shell carefully", tool_call))

    owner =
      Helpers.create_user!(%{
        email: "runtime-approval-pause-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-approval-pause-agent",
        tools: [approval_builtin_toolset("bash")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Inspect the shell carefully"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle
    assert result.session.last_processed_event_index == user_event.sequence
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "agent.tool_use"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(loaded_session.events, 4)
    final_idle_event = Enum.at(loaded_session.events, 5)

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.tool_use",
             "session.status_idle"
           ]

    assert blocked_tool_use_event.payload["tool_name"] == "bash"
    assert blocked_tool_use_event.payload["awaiting_confirmation"] == true

    assert final_idle_event.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [blocked_tool_use_event.id]
           }

    assert loaded_session.stop_reason == final_idle_event.stop_reason
  end

  test "run/2 resumes and executes a blocked tool after an allow confirmation" do
    tool_call = %{
      "id" => "toolu_allow_bash",
      "name" => "bash",
      "input" => %{"command" => "pwd && echo approved"}
    }

    configure_runtime_inference!(
      approval_resume_plug(
        "Run the guarded shell command",
        tool_call,
        "approved",
        "Ran the approved shell command."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-approval-allow-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-approval-allow-agent",
        tools: [approval_builtin_toolset("bash")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Run the guarded shell command"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_confirmation_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{"tool_use_id" => blocked_tool_use_event.id, "result" => "allow"}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.tool_result", "agent.message"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    tool_result_event = Enum.at(loaded_session.events, 8)
    final_idle_event = Enum.at(loaded_session.events, 10)

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.tool_use",
             "session.status_idle",
             "user.tool_confirmation",
             "session.status_running",
             "agent.tool_result",
             "agent.message",
             "session.status_idle"
           ]

    assert tool_result_event.payload["ok"] == true
    assert tool_result_event.payload["tool_name"] == "bash"

    assert tool_result_event.payload["result"] == %{
             "output" => "/\napproved\n",
             "exit_status" => 0
           }

    assert Enum.at(loaded_session.events, 9).content == [
             %{"type" => "text", "text" => "Ran the approved shell command."}
           ]

    assert final_idle_event.stop_reason == nil
    assert loaded_session.stop_reason == nil
  end

  test "run/2 emits a denied tool result and lets the provider continue after a deny confirmation" do
    tool_call = %{
      "id" => "toolu_deny_bash",
      "name" => "bash",
      "input" => %{"command" => "pwd && echo denied"}
    }

    configure_runtime_inference!(
      approval_resume_plug(
        "Decide whether to run the guarded command",
        tool_call,
        "permission_denied",
        "Handled the denied shell command."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-approval-deny-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-approval-deny-agent",
        tools: [approval_builtin_toolset("bash")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Decide whether to run the guarded command"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_confirmation_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{
              "tool_use_id" => blocked_tool_use_event.id,
              "result" => "deny",
              "deny_message" => "User denied the command."
            }
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.tool_result", "agent.message"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    tool_result_event = Enum.at(loaded_session.events, 8)
    final_idle_event = Enum.at(loaded_session.events, 10)

    assert tool_result_event.payload["ok"] == false
    assert tool_result_event.payload["tool_name"] == "bash"

    assert tool_result_event.payload["error"] == %{
             "error_type" => "permission_denied",
             "message" => "User denied the command."
           }

    assert Enum.at(loaded_session.events, 9).content == [
             %{"type" => "text", "text" => "Handled the denied shell command."}
           ]

    assert final_idle_event.stop_reason == nil
    assert loaded_session.stop_reason == nil
  end

  test "run/2 emits session.error for invalid tool confirmations and preserves the pending approval" do
    tool_call = %{
      "id" => "toolu_invalid_confirmation",
      "name" => "bash",
      "input" => %{"command" => "pwd && echo blocked"}
    }

    configure_runtime_inference!(approval_pause_plug("Pause for approval", tool_call))

    owner =
      Helpers.create_user!(%{
        email: "runtime-approval-invalid-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-approval-invalid-agent",
        tools: [approval_builtin_toolset("bash")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Pause for approval"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_confirmation_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{"tool_use_id" => Ecto.UUID.generate(), "result" => "allow"}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = List.last(loaded_session.events)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "invalid_tool_confirmation"

    assert loaded_session.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [blocked_tool_use_event.id]
           }
  end

  test "run/2 emits session.error for repeated tool confirmations after the approval is resolved" do
    tool_call = %{
      "id" => "toolu_repeat_confirmation",
      "name" => "bash",
      "input" => %{"command" => "pwd && echo once"}
    }

    configure_runtime_inference!(
      approval_resume_plug(
        "Approve the guarded command once",
        tool_call,
        "once",
        "Ran the command one time."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-approval-repeat-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-approval-repeat-agent",
        tools: [approval_builtin_toolset("bash")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Approve the guarded command once"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_first_confirmation]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{"tool_use_id" => blocked_tool_use_event.id, "result" => "allow"}
          }
        ],
        owner
      )

    assert {:ok, _allow_result} = SessionRuntime.run(session.id, owner)

    resolved_session = Helpers.get_session!(owner, session.id, [:events])

    {:ok, [_repeated_confirmation]} =
      SessionEventLog.append_user_events(
        resolved_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{"tool_use_id" => blocked_tool_use_event.id, "result" => "allow"}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = List.last(loaded_session.events)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "invalid_tool_confirmation"
    assert loaded_session.stop_reason == nil
  end

  test "run/2 pauses for custom tools and records requires_action stop reasons" do
    tool_call = %{
      "id" => "toolu_custom_release",
      "name" => "lookup_release",
      "input" => %{"package" => "jido_managed_agents"}
    }

    configure_runtime_inference!(
      custom_tool_pause_plug("Look up the release metadata", [tool_call])
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-custom-pause-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-custom-pause-agent",
        tools: [custom_tool("lookup_release", "Look up release metadata from the host app.")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Look up the release metadata"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert result.session.status == :idle
    assert result.session.last_processed_event_index == user_event.sequence

    assert Enum.map(result.emitted_events, & &1.type) == [
             "agent.thinking",
             "agent.custom_tool_use"
           ]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    custom_tool_use_event = Enum.at(loaded_session.events, 4)
    final_idle_event = Enum.at(loaded_session.events, 5)

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.custom_tool_use",
             "session.status_idle"
           ]

    assert custom_tool_use_event.payload["tool_name"] == "lookup_release"
    assert custom_tool_use_event.payload["tool_use_id"] == "toolu_custom_release"
    assert custom_tool_use_event.payload["input"] == %{"package" => "jido_managed_agents"}

    assert final_idle_event.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [custom_tool_use_event.id]
           }

    assert loaded_session.stop_reason == final_idle_event.stop_reason
  end

  test "run/2 resumes after a valid custom tool result" do
    tool_call = %{
      "id" => "toolu_custom_release_resume",
      "name" => "lookup_release",
      "input" => %{"package" => "jido_managed_agents"}
    }

    configure_runtime_inference!(
      custom_tool_resume_plug(
        "Resolve the release metadata",
        [tool_call],
        ["release-1.2.3"],
        "Handled the custom tool result."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-custom-resume-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-custom-resume-agent",
        tools: [custom_tool("lookup_release", "Look up release metadata from the host app.")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Resolve the release metadata"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    custom_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_custom_tool_result_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => custom_tool_use_event.id},
            content: [%{"type" => "text", "text" => "release-1.2.3"}]
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.message"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    message_event = Enum.at(loaded_session.events, 8)
    final_idle_event = Enum.at(loaded_session.events, 9)

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.custom_tool_use",
             "session.status_idle",
             "user.custom_tool_result",
             "session.status_running",
             "agent.message",
             "session.status_idle"
           ]

    assert message_event.content == [
             %{"type" => "text", "text" => "Handled the custom tool result."}
           ]

    assert final_idle_event.stop_reason == nil
    assert loaded_session.stop_reason == nil
  end

  test "run/2 waits for all blocking custom tool results before resuming" do
    tool_calls = [
      %{
        "id" => "toolu_custom_release_multi",
        "name" => "lookup_release",
        "input" => %{"package" => "jido_managed_agents"}
      },
      %{
        "id" => "toolu_custom_ticket_multi",
        "name" => "lookup_ticket",
        "input" => %{"ticket_id" => "TCK-42"}
      }
    ]

    configure_runtime_inference!(
      custom_tool_resume_plug(
        "Resolve both custom tools",
        tool_calls,
        ["release-1.2.3", "ticket-42-ready"],
        "Handled both custom tool results."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-custom-multi-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-custom-multi-agent",
        tools: [
          custom_tool("lookup_release", "Look up release metadata from the host app."),
          custom_tool("lookup_ticket", "Look up ticket metadata from the host app.")
        ]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Resolve both custom tools"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    first_custom_tool_use_event = Enum.at(paused_session.events, 4)
    second_custom_tool_use_event = Enum.at(paused_session.events, 5)

    assert paused_session.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [first_custom_tool_use_event.id, second_custom_tool_use_event.id]
           }

    {:ok, [_first_result_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => first_custom_tool_use_event.id},
            content: [%{"type" => "text", "text" => "release-1.2.3"}]
          }
        ],
        owner
      )

    assert {:ok, first_result} = SessionRuntime.run(session.id, owner)
    assert first_result.emitted_events == []

    partially_resolved_session = Helpers.get_session!(owner, session.id, [:events])

    assert partially_resolved_session.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [second_custom_tool_use_event.id]
           }

    {:ok, [_second_result_event]} =
      SessionEventLog.append_user_events(
        partially_resolved_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => second_custom_tool_use_event.id},
            content: [%{"type" => "text", "text" => "ticket-42-ready"}]
          }
        ],
        owner
      )

    assert {:ok, second_result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(second_result.emitted_events, & &1.type) == ["agent.message"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.custom_tool_use",
             "agent.custom_tool_use",
             "session.status_idle",
             "user.custom_tool_result",
             "user.custom_tool_result",
             "session.status_running",
             "agent.message",
             "session.status_idle"
           ]

    assert loaded_session.stop_reason == nil

    assert Enum.at(loaded_session.events, 10).content == [
             %{"type" => "text", "text" => "Handled both custom tool results."}
           ]
  end

  test "run/2 emits session.error for invalid custom tool result IDs and preserves the pending request" do
    tool_call = %{
      "id" => "toolu_custom_invalid",
      "name" => "lookup_release",
      "input" => %{"package" => "jido_managed_agents"}
    }

    configure_runtime_inference!(custom_tool_pause_plug("Wait on a custom tool", [tool_call]))

    owner =
      Helpers.create_user!(%{
        email: "runtime-custom-invalid-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-custom-invalid-agent",
        tools: [custom_tool("lookup_release", "Look up release metadata from the host app.")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Wait on a custom tool"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_custom_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_invalid_result_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => Ecto.UUID.generate()},
            content: [%{"type" => "text", "text" => "ignored"}]
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = List.last(loaded_session.events)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "invalid_custom_tool_result"

    assert loaded_session.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [blocked_custom_tool_use_event.id]
           }
  end

  test "run/2 emits session.error for duplicate custom tool results after the request is resolved" do
    tool_call = %{
      "id" => "toolu_custom_duplicate",
      "name" => "lookup_release",
      "input" => %{"package" => "jido_managed_agents"}
    }

    configure_runtime_inference!(
      custom_tool_resume_plug(
        "Resolve one custom tool result",
        [tool_call],
        ["release-1.2.3"],
        "Handled the first custom tool result."
      )
    )

    owner =
      Helpers.create_user!(%{
        email: "runtime-custom-duplicate-#{System.unique_integer([:positive])}@example.com"
      })

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-custom-duplicate-agent",
        tools: [custom_tool("lookup_release", "Look up release metadata from the host app.")]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Resolve one custom tool result"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, _pause_result} = SessionRuntime.run(session, owner)

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    custom_tool_use_event = Enum.at(paused_session.events, 4)

    {:ok, [_first_result_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => custom_tool_use_event.id},
            content: [%{"type" => "text", "text" => "release-1.2.3"}]
          }
        ],
        owner
      )

    assert {:ok, _first_resolution} = SessionRuntime.run(session.id, owner)

    resolved_session = Helpers.get_session!(owner, session.id, [:events])

    {:ok, [_duplicate_result_event]} =
      SessionEventLog.append_user_events(
        resolved_session,
        [
          %{
            type: "user.custom_tool_result",
            payload: %{"custom_tool_use_id" => custom_tool_use_event.id},
            content: [%{"type" => "text", "text" => "release-1.2.3"}]
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session.id, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = List.last(loaded_session.events)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "invalid_custom_tool_result"
    assert loaded_session.stop_reason == nil
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

  defp success_anthropic_plug(expected_prompt, reply_text) do
    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["model"] == "claude-sonnet-4-6"
      assert params["system"] == "Stay precise."

      assert get_in(params, ["messages", Access.at(0), "content"]) == expected_prompt or
               get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"]) ==
                 expected_prompt

      response =
        Jason.encode!(%{
          "id" => "msg_runtime_success",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [%{"type" => "text", "text" => reply_text}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 18}
        })

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, response)
    end
  end

  defp provider_failure_plug do
    fn conn ->
      assert conn.host == "req-llm-provider.test"
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["model"] == "claude-haiku-4-5"

      response =
        Jason.encode!(%{
          "error" => %{
            "type" => "api_error",
            "message" => "provider unavailable"
          }
        })

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(500, response)
    end
  end

  defp filesystem_tool_plug(expected_prompt, tool_calls, final_reply_text) do
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
              "id" => "msg_runtime_tool_call_1",
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
              "usage" => %{"input_tokens" => 24, "output_tokens" => 12}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          encoded_request = Jason.encode!(params)

          Enum.each(tool_calls, fn tool_call ->
            assert encoded_request =~ tool_call["id"]
            assert encoded_request =~ tool_call["name"]
          end)

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_tool_call_2",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => final_reply_text}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 28, "output_tokens" => 10}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp normalized_prompt(params) do
    get_in(params, ["messages", Access.at(0), "content"]) ||
      get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"])
  end

  defp callable_agent_link(owner, callable_agent, callable_agent_version_id, position) do
    %{
      user_id: owner.id,
      callable_agent_id: callable_agent.id,
      callable_agent_version_id: callable_agent_version_id,
      position: position,
      metadata: %{}
    }
  end

  defp delegate_tool_name(agent_id), do: "delegate_to_" <> agent_id

  defp delegation_plug(
         expected_root_prompt,
         delegate_tool_name,
         delegate_message,
         delegate_reply_text,
         final_reply_text
       ) do
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

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_root_prompt
          assert Enum.map(params["tools"], & &1["name"]) == [delegate_tool_name]

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_delegate_root_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_delegate_root",
                  "name" => delegate_tool_name,
                  "input" => %{"message" => delegate_message}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 21, "output_tokens" => 8}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          assert normalized_prompt(params) == delegate_message
          assert Map.get(params, "tools", []) == []

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_delegate_thread",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => delegate_reply_text}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 13, "output_tokens" => 7}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        2 ->
          encoded_request = Jason.encode!(params)

          assert encoded_request =~ delegate_tool_name
          assert encoded_request =~ delegate_reply_text

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_delegate_root_2",
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

  defp nested_delegation_plug(
         expected_root_prompt,
         root_delegate_tool_name,
         delegate_message,
         nested_delegate_tool_name
       ) do
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

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_root_prompt
          assert Enum.map(params["tools"], & &1["name"]) == [root_delegate_tool_name]

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_nested_root",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_nested_root",
                  "name" => root_delegate_tool_name,
                  "input" => %{"message" => delegate_message}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 19, "output_tokens" => 8}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          assert normalized_prompt(params) == delegate_message
          assert Map.get(params, "tools", []) == []

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_nested_delegate",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_nested_delegate",
                  "name" => nested_delegate_tool_name,
                  "input" => %{"message" => "go deeper"}
                }
              ],
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

  defp always_allow_builtin_toolset do
    %{
      "type" => "agent_toolset_20260401",
      "default_config" => %{"permission_policy" => "always_allow"}
    }
  end

  defp approval_builtin_toolset(tool_name) do
    %{
      "type" => "agent_toolset_20260401",
      "default_config" => %{"permission_policy" => "always_allow"},
      "configs" => %{
        tool_name => %{"permission_policy" => "always_ask"}
      }
    }
  end

  defp approval_pause_plug(expected_prompt, tool_call) do
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
      assert normalized_prompt(params) == expected_prompt

      case request_number do
        0 ->
          response =
            Jason.encode!(%{
              "id" => "msg_runtime_approval_pause",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => tool_call["id"],
                  "name" => tool_call["name"],
                  "input" => tool_call["input"]
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 24, "output_tokens" => 10}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp approval_resume_plug(expected_prompt, tool_call, expected_result_snippet, final_reply_text) do
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

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_approval_resume_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => tool_call["id"],
                  "name" => tool_call["name"],
                  "input" => tool_call["input"]
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 24, "output_tokens" => 10}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          encoded_request = Jason.encode!(params)

          assert encoded_request =~ tool_call["id"]
          assert encoded_request =~ tool_call["name"]
          assert encoded_request =~ expected_result_snippet

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_approval_resume_2",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => final_reply_text}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 28, "output_tokens" => 11}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp custom_tool(name, description) do
    %{
      "type" => "custom",
      "name" => name,
      "description" => description,
      "input_schema" => custom_tool_input_schema(name),
      "permission_policy" => "always_allow"
    }
  end

  defp custom_tool_input_schema("lookup_ticket") do
    %{
      "type" => "object",
      "properties" => %{"ticket_id" => %{"type" => "string"}},
      "required" => ["ticket_id"]
    }
  end

  defp custom_tool_input_schema(_tool_name) do
    %{
      "type" => "object",
      "properties" => %{"package" => %{"type" => "string"}},
      "required" => ["package"]
    }
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

      assert Enum.map(params["tools"], & &1["name"]) ==
               tool_calls |> Enum.map(& &1["name"]) |> Enum.sort()

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_custom_pause",
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
              "usage" => %{"input_tokens" => 18, "output_tokens" => 7}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp custom_tool_resume_plug(
         expected_prompt,
         tool_calls,
         expected_result_snippets,
         final_reply_text
       ) do
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

      assert Enum.map(params["tools"], & &1["name"]) ==
               tool_calls |> Enum.map(& &1["name"]) |> Enum.sort()

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_custom_resume_1",
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
              "usage" => %{"input_tokens" => 18, "output_tokens" => 7}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          encoded_request = Jason.encode!(params)

          Enum.each(tool_calls, fn tool_call ->
            assert encoded_request =~ tool_call["id"]
            assert encoded_request =~ tool_call["name"]
          end)

          Enum.each(expected_result_snippets, fn snippet ->
            assert encoded_request =~ snippet
          end)

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_custom_resume_2",
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

  defmodule StubSearchAdapter do
    @behaviour JidoManagedAgents.Sessions.RuntimeWeb.SearchAdapter

    @impl true
    def search(query, opts) do
      send(self(), {:stub_session_web_search_called, query, opts})

      case Process.get(:session_runtime_web_search_response) do
        nil -> {:ok, []}
        response -> response
      end
    end
  end
end
