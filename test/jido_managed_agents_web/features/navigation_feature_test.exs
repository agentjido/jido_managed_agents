defmodule JidoManagedAgentsWeb.NavigationFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureFixtures
  import JidoManagedAgentsWeb.FeatureHelpers

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "overview quick actions route into the latest pending session", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    environment = Helpers.create_environment!(user)

    %{session: pending_session} =
      build_approval_session(user, environment,
        title: "Guarded cleanup review",
        agent_name: "Guarded Operator"
      )

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console")
    |> assert_has("body", text: "Open Latest Pending Session")
    |> assert_has("body", text: pending_session.title)
    |> click_link(
      "a[href='/console/sessions/#{pending_session.id}']",
      "Open Latest Pending Session"
    )
    |> assert_path(~p"/console/sessions/#{pending_session.id}")
    |> assert_has("body", text: "rm -rf tmp/build")
  end

  test "agent library search narrows results and opens the selected detail page", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user

    target_agent =
      Helpers.create_agent!(user, %{
        name: "Research Navigator",
        description: "Synthesizes domain findings into action items."
      })

    other_agent =
      Helpers.create_agent!(user, %{
        name: "Runbook Maintainer",
        description: "Keeps runbooks tidy."
      })

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/agents")
    |> type("input[name='filters[search]']", target_agent.name)
    |> assert_has("body", text: target_agent.name)
    |> refute_has("body", text: other_agent.name)
    |> click_link(target_agent.name)
    |> assert_path(~p"/console/agents/#{target_agent.id}")
    |> assert_has("h1", text: target_agent.name)
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "mobile console uses the sheet nav and hides the theme toggle", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console")
    |> refute_has("[data-theme-toggle]")
    |> assert_has(".console-bottom-nav")
    |> click(".console-mobile-only-inline-flex")
    |> assert_has("#console-mobile-sheet", text: "Vaults")
    |> click_link("#console-mobile-sheet a[href='/console/vaults']", "Vaults")
    |> assert_path(~p"/console/vaults")
    |> assert_has("h1", text: "Vaults & Credentials")
  end
end
