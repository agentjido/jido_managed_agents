defmodule JidoManagedAgentsWeb.FeatureFixtures do
  @moduledoc false

  import ExUnit.Assertions

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventLog,
    SessionThread,
    SessionThreads
  }

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  def build_normal_session(owner, environment, opts \\ []) do
    %{session: session, primary_thread: primary_thread, agent_name: agent_name} =
      create_session_fixture(owner, environment, opts)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Inspect the workspace"}],
            payload: %{}
          }
        ],
        owner
      )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.status_running",
      [],
      %{"status" => "running"}
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.thinking",
      [%{"type" => "text", "text" => "Planning the filesystem inspection."}],
      %{"provider" => "anthropic", "model" => "claude-sonnet-4-6"}
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.tool_use",
      [
        %{
          "type" => "tool_use",
          "id" => "toolu_ls",
          "name" => "bash",
          "input" => %{"command" => "ls -la"}
        }
      ],
      %{
        "phase" => "tool_start",
        "tool_use_id" => "toolu_ls",
        "tool_name" => "bash",
        "input" => %{"command" => "ls -la"}
      }
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.tool_result",
      [
        %{
          "type" => "tool_result",
          "tool_use_id" => "toolu_ls",
          "content" => [%{"type" => "text", "text" => "total 0\n"}],
          "is_error" => false
        }
      ],
      %{
        "phase" => "tool_complete",
        "tool_use_id" => "toolu_ls",
        "tool_name" => "bash",
        "input" => %{"command" => "ls -la"},
        "ok" => true,
        "result" => %{"output" => "total 0\n", "exit_status" => 0}
      }
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.message",
      [%{"type" => "text", "text" => "Workspace inspection complete."}],
      %{
        "provider" => "anthropic",
        "model" => "claude-sonnet-4-6",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 18, "total_tokens" => 30}
      }
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.status_idle",
      [],
      %{"status" => "idle"}
    )

    %{session: load_session_by_id!(owner, session.id), agent_name: agent_name}
  end

  def build_approval_session(owner, environment, opts \\ []) do
    %{session: session, primary_thread: primary_thread} =
      create_session_fixture(owner, environment, opts)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Run the guarded cleanup"}],
            payload: %{}
          }
        ],
        owner
      )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.status_running",
      [],
      %{"status" => "running"}
    )

    blocked_tool_use_event =
      create_session_event!(
        owner,
        session,
        primary_thread.id,
        "agent.tool_use",
        [
          %{
            "type" => "tool_use",
            "id" => "toolu_guarded_cleanup",
            "name" => "bash",
            "input" => %{"command" => "rm -rf tmp/build"}
          }
        ],
        %{
          "phase" => "tool_start",
          "tool_use_id" => "toolu_guarded_cleanup",
          "tool_name" => "bash",
          "input" => %{"command" => "rm -rf tmp/build"},
          "awaiting_confirmation" => true
        }
      )

    stop_reason = %{"type" => "requires_action", "event_ids" => [blocked_tool_use_event.id]}

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.status_idle",
      [],
      %{"status" => "idle"},
      stop_reason
    )

    update_session!(owner, session, %{stop_reason: stop_reason})

    %{
      session: load_session_by_id!(owner, session.id),
      blocked_tool_use_event: blocked_tool_use_event
    }
  end

  def build_threaded_session(owner, environment, opts \\ []) do
    %{session: session, primary_thread: primary_thread} =
      create_session_fixture(owner, environment, opts)

    delegate_agent = Helpers.create_agent!(owner, %{name: "Delegate Specialist"})
    delegate_version = Helpers.latest_agent_version!(owner, delegate_agent)

    delegate_thread =
      create_session_thread!(owner, session, delegate_agent.id, delegate_version.id, %{
        parent_thread_id: primary_thread.id
      })

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.thread_created",
      [],
      %{
        "session_thread_id" => delegate_thread.id,
        "parent_thread_id" => primary_thread.id,
        "agent_id" => delegate_agent.id,
        "agent_version" => delegate_version.version,
        "model" => %{"id" => "claude-sonnet-4-6", "speed" => "standard"}
      }
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.thread_message_sent",
      [%{"type" => "text", "text" => "Investigate the threaded trace."}],
      %{
        "from_thread_id" => primary_thread.id,
        "to_thread_id" => delegate_thread.id,
        "tool_use_id" => "toolu_delegate",
        "tool_name" => "delegate_investigator",
        "callable_agent_id" => delegate_agent.id
      }
    )

    create_session_event!(
      owner,
      session,
      delegate_thread.id,
      "agent.thread_message_received",
      [%{"type" => "text", "text" => "Investigate the threaded trace."}],
      %{
        "from_thread_id" => primary_thread.id,
        "tool_use_id" => "toolu_delegate",
        "tool_name" => "delegate_investigator",
        "callable_agent_id" => delegate_agent.id
      },
      nil,
      "thread"
    )

    create_session_event!(
      owner,
      session,
      primary_thread.id,
      "agent.message",
      [%{"type" => "text", "text" => "Primary summary ready."}],
      %{}
    )

    create_session_event!(
      owner,
      session,
      delegate_thread.id,
      "agent.message",
      [%{"type" => "text", "text" => "Delegate trace ready."}],
      %{},
      nil,
      "thread"
    )

    %{session: load_session_by_id!(owner, session.id), delegate_thread: delegate_thread}
  end

  def get_environment_by_name!(user, name) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end

  def get_agent_by_name!(user, name) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.load(AgentCatalog.latest_version_load())
    |> Ash.read_one!()
  end

  def get_vault_by_name!(user, name) do
    Vault
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end

  def get_credential_by_url!(user, vault, url) do
    Credential
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
    |> Ash.Query.filter(vault_id == ^vault.id and mcp_server_url == ^url)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end

  def get_session_by_title!(user, title) do
    Session
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
    |> Ash.Query.filter(title == ^title)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.load([
      :agent,
      :agent_version,
      :session_vaults,
      :events,
      threads: [:agent, :agent_version]
    ])
    |> Ash.read_one!()
  end

  def with_mock_runtime(expected_prompt, reply_text, fun) when is_function(fun, 0) do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_api_key = Application.get_env(:req_llm, :anthropic_api_key)

    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.SessionRuntime,
      anthropic_compatible_provider: :anthropic,
      max_tokens: 1024,
      temperature: 0.2,
      timeout: 30_000,
      req_http_options: [plug: success_anthropic_plug(expected_prompt, reply_text)]
    )

    try do
      fun.()
    after
      restore_runtime_env(
        :jido_managed_agents,
        JidoManagedAgents.Sessions.SessionRuntime,
        previous_runtime
      )

      restore_runtime_env(:req_llm, :anthropic_api_key, previous_api_key)
    end
  end

  defp create_session_fixture(owner, environment, opts) do
    agent_name =
      Keyword.get(opts, :agent_name, "session-agent-#{System.unique_integer([:positive])}")

    agent =
      Helpers.create_agent!(owner, %{
        name: agent_name,
        model: %{"id" => "claude-sonnet-4-6", "speed" => "standard"}
      })

    version = Helpers.latest_agent_version!(owner, agent)
    workspace = Helpers.create_workspace!(owner, agent)

    session =
      Helpers.create_session!(owner, agent, version, environment, workspace, %{
        title: Keyword.get(opts, :title, "session-#{System.unique_integer([:positive])}")
      })

    %{
      session: session,
      primary_thread: primary_thread_for!(owner, session),
      agent_name: agent_name
    }
  end

  defp load_session_by_id!(owner, session_id) do
    Session
    |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: owner, domain: Sessions)
    |> Ash.Query.load([:agent, :agent_version, :events, threads: [:agent, :agent_version]])
    |> Ash.read_one!()
  end

  defp update_session!(owner, session, attrs) do
    session
    |> Ash.Changeset.for_update(:update, attrs, actor: owner, domain: Sessions)
    |> Ash.update!()
  end

  defp primary_thread_for!(owner, session) do
    {:ok, thread} = SessionThreads.ensure_primary_thread(session, owner, [:agent_version])
    thread
  end

  defp create_session_thread!(owner, session, agent_id, agent_version_id, attrs) do
    SessionThread
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        session_id: session.id,
        agent_id: agent_id,
        agent_version_id: agent_version_id,
        parent_thread_id: Map.get(attrs, :parent_thread_id),
        role: Map.get(attrs, :role, :delegate),
        status: Map.get(attrs, :status, :idle),
        metadata: %{scope: "feature-test"}
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp create_session_event!(
         owner,
         session,
         thread_id,
         type,
         content,
         payload,
         stop_reason \\ nil,
         stream_scope \\ "both"
       ) do
    SessionEvent
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        session_id: session.id,
        session_thread_id: thread_id,
        sequence: next_event_sequence!(owner, session),
        type: type,
        content: content,
        payload: payload,
        stop_reason: stop_reason,
        metadata: %{"stream_scope" => stream_scope}
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp next_event_sequence!(owner, session) do
    session
    |> reload_session!(owner)
    |> Map.fetch!(:events)
    |> List.last()
    |> case do
      nil -> 0
      event -> event.sequence + 1
    end
  end

  defp reload_session!(session, owner), do: load_session_by_id!(owner, session.id)

  defp success_anthropic_plug(expected_prompt, reply_text) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      assert get_in(params, ["messages", Access.at(0), "content"]) == expected_prompt or
               get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"]) ==
                 expected_prompt

      response =
        Jason.encode!(%{
          "id" => "msg_console_success",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [%{"type" => "text", "text" => reply_text}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 18}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response)
    end
  end

  defp restore_runtime_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_runtime_env(app, key, value), do: Application.put_env(app, key, value)
end
