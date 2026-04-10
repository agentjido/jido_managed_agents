defmodule JidoManagedAgentsWeb.SessionObservabilityLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventLog,
    SessionThread,
    SessionThreads
  }

  alias JidoManagedAgentsWeb.ConsoleHelpers
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "requires an authenticated user for session pages", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/sessions")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/sessions/unknown")
  end

  test "session list and normal trace detail render status, model, timeline, raw events, tool executions, and metrics",
       %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})
    environment = Helpers.create_environment!(user)

    %{session: session, agent_name: agent_name} =
      build_normal_session(user, environment,
        title: "Release Investigation",
        agent_name: "Analyst Agent"
      )

    other = Helpers.create_user!()
    other_environment = Helpers.create_environment!(other)
    _other_session = build_normal_session(other, other_environment, title: "Other User Session")

    {:ok, list_view, list_html} = live(conn, ~p"/console/sessions")

    assert list_html =~ "Sessions"
    assert list_html =~ "Release Investigation"
    assert list_html =~ agent_name
    assert list_html =~ ConsoleHelpers.format_timestamp(session.created_at)
    refute list_html =~ "Other User Session"
    assert element(list_view, "#session-card-#{session.id}") |> render() =~ "claude-sonnet-4-6"

    {:ok, detail_view, detail_html} = live(conn, ~p"/console/sessions/#{session.id}")

    assert detail_html =~ "Trace Timeline"
    assert detail_html =~ "Tool Execution"
    assert detail_html =~ "Raw Events"
    assert element(detail_view, "#session-tool-executions") |> render() =~ "ls -la"
    assert element(detail_view, "#session-tool-executions") |> render() =~ "total 0"
    assert element(detail_view, "#session-raw-events") |> render() =~ "agent.message"

    metrics_html = element(detail_view, "#session-metrics") |> render()

    assert metrics_html =~ "Input Tokens"
    assert metrics_html =~ "12"
    assert metrics_html =~ "30"
  end

  test "errored sessions render the latest error and tolerate missing metrics", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})
    environment = Helpers.create_environment!(user)
    %{session: session} = build_errored_session(user, environment)

    {:ok, view, html} = live(conn, ~p"/console/sessions/#{session.id}")

    assert html =~ "Latest error"
    assert html =~ "Anthropic request timed out"
    assert element(view, "#session-raw-events") |> render() =~ "session.error"
    assert element(view, "#session-metrics") |> render() =~ "No provider metrics were recorded"
  end

  test "approval-needed sessions render allow and deny controls for blocked tool uses", %{
    conn: conn
  } do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})
    environment = Helpers.create_environment!(user)

    %{session: session, blocked_tool_use_event: blocked_tool_use_event} =
      build_approval_session(user, environment)

    {:ok, view, html} = live(conn, ~p"/console/sessions/#{session.id}")

    assert html =~ "Awaiting approval"
    assert html =~ "rm -rf tmp/build"
    assert has_element?(view, "#confirm-allow-#{blocked_tool_use_event.id}")
    assert has_element?(view, "#confirm-deny-#{blocked_tool_use_event.id}")

    assert element(view, "#pending-confirmation-#{blocked_tool_use_event.id}") |> render() =~
             "user.tool_confirmation"
  end

  test "threaded sessions support drill-down into thread-specific traces", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})
    environment = Helpers.create_environment!(user)

    %{session: session, delegate_thread: delegate_thread} =
      build_threaded_session(user, environment)

    {:ok, view, html} = live(conn, ~p"/console/sessions/#{session.id}")

    assert html =~ "Thread traces"
    assert html =~ "All traces"
    assert html =~ "Primary summary ready."
    assert html =~ "Delegate trace ready."

    render_click(element(view, "#trace-scope-thread-#{delegate_thread.id}"))
    assert_patch(view, ~p"/console/sessions/#{session.id}?thread_id=#{delegate_thread.id}")

    thread_trace = element(view, "#session-trace") |> render()
    raw_html = element(view, "#session-raw-events") |> render()

    assert thread_trace =~ "Delegate trace ready."
    refute thread_trace =~ "Primary summary ready."
    assert raw_html =~ delegate_thread.id
  end

  defp build_normal_session(owner, environment, opts) do
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

  defp build_errored_session(owner, environment) do
    %{session: session, primary_thread: primary_thread} =
      create_session_fixture(owner, environment,
        title: "Errored Session",
        agent_name: "Failure Agent"
      )

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Trigger a provider failure"}],
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
      "session.error",
      [],
      %{
        "error_type" => "provider_error",
        "message" => "Anthropic request timed out"
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

    %{session: load_session_by_id!(owner, session.id)}
  end

  defp build_approval_session(owner, environment) do
    %{session: session, primary_thread: primary_thread} =
      create_session_fixture(
        owner,
        environment,
        title: "Approval Session",
        agent_name: "Guarded Operator"
      )

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

  defp build_threaded_session(owner, environment) do
    %{session: session, primary_thread: primary_thread} =
      create_session_fixture(owner, environment,
        title: "Threaded Session",
        agent_name: "Coordinator"
      )

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
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: owner, domain: Sessions)
      |> Ash.Query.load([:agent, :agent_version, :events, threads: [:agent, :agent_version]])

    Ash.read_one!(query)
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
        metadata: %{scope: "session-observability-live-test"}
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
end
