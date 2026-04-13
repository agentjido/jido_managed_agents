defmodule JidoManagedAgentsWeb.SessionFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureFixtures
  import JidoManagedAgentsWeb.FeatureHelpers

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "agent detail launches a session from the sessions tab", %{conn: conn} do
    credentials = create_password_user!()
    title = "Sprint retro facilitator"
    prompt = "Pull together the top blockers for the last sprint."

    agent =
      Helpers.create_agent!(credentials.user, %{
        name: "Retro Facilitator",
        description: "Summarize blockers and next steps."
      })

    environment = Helpers.create_environment!(credentials.user, %{name: "Delivery Sandbox"})

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/agents/#{agent.id}")
    |> click_link("a[href*='tab=sessions']", "Sessions")
    |> assert_has("#agent-launch-form")
    |> fill_in("#launch-title", "Title", with: title)
    |> select("Environment", option: environment.name, exact_option: true)
    |> fill_in("#launch-prompt", "Opening message", with: prompt)
    |> click_button("Start Session")
    |> assert_has("#session-composer")
    |> assert_has("body", text: prompt)
    |> evaluate("window.location.pathname", fn path ->
      assert path =~ ~r{^/console/sessions/[^/]+$}
    end)
  end

  test "session detail exposes transcript composition and debug drill-down", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    environment = Helpers.create_environment!(user)

    %{session: session_record} =
      build_normal_session(user, environment,
        title: "Release Investigation",
        agent_name: "Analyst Agent"
      )

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/sessions")
    |> assert_has("#session-card-#{session_record.id}", text: "Release Investigation")
    |> click_link("#session-card-#{session_record.id}", "Release Investigation")
    |> assert_path(~p"/console/sessions/#{session_record.id}")
    |> assert_has("#session-composer")
    |> click_button("Debug")
    |> click_button("Tools")
    |> assert_has("#session-tool-executions", text: "ls -la")
    |> click_button("Raw Events")
    |> assert_has("#session-raw-events", text: "agent.message")
    |> click_button("Metrics")
    |> assert_has("#session-metrics", text: "Input Tokens")
  end

  test "thread scope filtering keeps delegate traces isolated in the browser", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    environment = Helpers.create_environment!(user)

    %{session: session_record, delegate_thread: delegate_thread} =
      build_threaded_session(user, environment,
        title: "Threaded Session",
        agent_name: "Coordinator"
      )

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/sessions/#{session_record.id}")
    |> assert_has("#session-trace", text: "Primary summary ready.")
    |> assert_has("#session-trace", text: "Delegate trace ready.")
    |> click_link(
      "#trace-scope-thread-#{delegate_thread.id}",
      "Delegate · Delegate Specialist"
    )
    |> assert_has("#session-trace", text: "Delegate trace ready.")
    |> refute_has("#session-trace", text: "Primary summary ready.")
    |> evaluate("window.location.search", fn search ->
      assert search == "?thread_id=#{delegate_thread.id}"
    end)
    |> click_button("Debug")
    |> click_button("Raw Events")
    |> assert_has("#session-raw-events", text: delegate_thread.id)
  end

  test "approval-required sessions render allow and deny controls", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    environment = Helpers.create_environment!(user)

    %{session: session_record, blocked_tool_use_event: blocked_tool_use_event} =
      build_approval_session(user, environment,
        title: "Approval Session",
        agent_name: "Guarded Operator"
      )

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/sessions/#{session_record.id}")
    |> assert_has("body", text: "Awaiting approval")
    |> assert_has("#pending-confirmation-#{blocked_tool_use_event.id}", text: "rm -rf tmp/build")
    |> assert_has("#confirm-allow-#{blocked_tool_use_event.id}")
    |> assert_has("#confirm-deny-#{blocked_tool_use_event.id}")
  end

  test "session detail composer supports a follow-up conversation with mocked runtime output", %{
    conn: conn
  } do
    credentials = create_password_user!()
    user = credentials.user
    prompt = "Follow up on the error budget."
    reply = "Error budget is stable."

    agent = Helpers.create_agent!(user, %{name: "Conversation Agent"})
    environment = Helpers.create_environment!(user, %{name: "Conversation Sandbox"})
    workspace = Helpers.create_workspace!(user, agent)
    version = Helpers.latest_agent_version!(user, agent)

    session_record =
      Helpers.create_session!(user, agent, version, environment, workspace, %{
        title: "Conversation Session",
        status: :idle
      })

    with_mock_runtime(prompt, reply, fn ->
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/sessions/#{session_record.id}")
      |> assert_has("#session-composer")
      |> type("textarea[name='composer[prompt]']", prompt)
      |> click_button("Send")
      |> assert_has("#session-trace", text: prompt, timeout: 5000)
      |> assert_has("#session-trace", text: reply, timeout: 5000)
    end)
  end
end
