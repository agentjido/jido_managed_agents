defmodule JidoManagedAgentsWeb.ConsoleFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureHelpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "user can sign in from the home page and reach the overview", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in_through_home(credentials)
    |> assert_path(~p"/console")
    |> assert_has("h1", text: "Overview")
    |> assert_has("body", text: credentials.user.email)
  end

  test "authenticated users can generate api keys from the docs screen", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit(~p"/console/api-docs")
    |> assert_path(~p"/console/api-docs")
    |> assert_has("h1", text: "API Documentation")
    |> click_button("Sessions")
    |> assert_has("body", text: "/v1/sessions")
    |> click_button("Generate API key")
    |> assert_has("#generated-api-key", text: "jidomanagedagents")
  end

  test "agent builder waits for submit before showing validation and supports capability scaffolding",
       %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit(~p"/console/agents/new")
    |> assert_path(~p"/console/agents/new")
    |> assert_has("h1", text: "New Agent")
    |> refute_has("#builder-errors")
    |> fill_in("Name", with: "Browser Test Agent")
    |> click_button("#add-tool-button", "Add Tool")
    |> assert_has("#agent_tools_1_type")
    |> click_button("#add-mcp-server-button", "Add")
    |> assert_has("#agent_mcp_servers_0_name")
    |> click_button("#add-skill-button", "Add")
    |> assert_has("#agent_skills_0_id")
    |> click_button("#add-callable-agent-button", "Add")
    |> assert_has("#agent_callable_agents_0_id")
  end
end
