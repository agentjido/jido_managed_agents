defmodule JidoManagedAgentsWeb.AgentBuilderFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureFixtures
  import JidoManagedAgentsWeb.FeatureHelpers

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "agent builder creates versions and archives an agent", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    name = "Research Coordinator"
    updated_name = "Research Coordinator v2"

    session =
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/agents/new")
      |> assert_has("#resolved-model-spec")
      |> fill_in("Name", with: name)
      |> fill_in("Description", with: "Coordinates release research.")
      |> fill_in("System Prompt", with: "Stay precise and cite evidence.")
      |> click_button("#agent-save-button", "Create Agent")

    agent = get_agent_by_name!(user, name)

    session =
      session
      |> assert_path(~p"/console/agents/#{agent.id}/edit")
      |> assert_has("#agent-archive-button")
      |> fill_in("Name", with: updated_name)
      |> click_button("#agent-save-button", "Save New Version")
      |> click_button("Version History")
      |> assert_has("#version-list", text: "v2")
      |> click_button("#agent-archive-button", "Archive")
      |> assert_has("body", text: "Archive this agent?")
      |> click_button("Confirm Archive")
      |> assert_has("body", text: "Agent archived.")

    updated_agent = get_agent_by_name!(user, updated_name)

    session
    |> visit_live(~p"/console/agents")
    |> click_button("Archived")
    |> assert_has("body", text: updated_name)

    assert updated_agent.latest_version.version == 2
  end

  test "edit page test run streams inline events with a mocked runtime", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    prompt = "Inspect the release status"
    reply = "The release status is green."

    agent = Helpers.create_agent!(user, %{name: "Runner Agent"})
    environment = Helpers.create_environment!(user, %{name: "QA Sandbox"})

    with_mock_runtime(prompt, reply, fn ->
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/agents/#{agent.id}/edit")
      |> click_button("Test Run")
      |> assert_has("#agent-runner-form")
      |> set_form_value(
        "#agent-runner-form select[name='runner[environment_id]']",
        environment.id
      )
      |> fill_in("Session Title", with: "Launch Smoke Test")
      |> fill_in("Prompt", with: prompt)
      |> click_button("#runner-submit-button", "Launch Session")
      |> assert_has("#runner-notice", text: "Streaming inline from session", timeout: 5000)
      |> assert_has("#runner-events", text: "agent.message", timeout: 5000)
      |> assert_has("#runner-events", text: reply, timeout: 5000)
    end)

    launched_session = get_session_by_title!(user, "Launch Smoke Test")

    assert launched_session.agent_id == agent.id
    assert launched_session.environment_id == environment.id
  end

  test "edit page surfaces runner conflicts when the workspace already has an active session", %{
    conn: conn
  } do
    credentials = create_password_user!()
    user = credentials.user
    agent = Helpers.create_agent!(user, %{name: "Conflict Agent"})
    environment = Helpers.create_environment!(user, %{name: "Conflict Sandbox"})
    workspace = Helpers.create_workspace!(user, agent)
    version = Helpers.latest_agent_version!(user, agent)

    Helpers.create_session!(user, agent, version, environment, workspace, %{
      title: "Existing Session",
      status: :idle
    })

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/agents/#{agent.id}/edit")
    |> click_button("Test Run")
    |> assert_has("#agent-runner-form")
    |> set_form_value("#agent-runner-form select[name='runner[environment_id]']", environment.id)
    |> fill_in("Session Title", with: "Blocked Launch")
    |> fill_in("Prompt", with: "Inspect the workspace")
    |> click_button("#runner-submit-button", "Launch Session")
    |> assert_has("#runner-error", text: "workspace already has an active session", timeout: 5000)
  end
end
