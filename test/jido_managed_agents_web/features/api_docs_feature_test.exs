defmodule JidoManagedAgentsWeb.ApiDocsFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureHelpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "api docs rotate snippets and generated keys through the examples", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/api-docs")
    |> assert_has("body", text: "/v1/agents")
    |> assert_has("body", text: "YOUR_API_KEY")
    |> click_button("Sessions")
    |> assert_has("body", text: "/v1/sessions")
    |> assert_has("body", text: "environment_id")
    |> click_button("Vaults")
    |> assert_has("body", text: "/v1/vaults")
    |> assert_has("body", text: "display_metadata")
    |> set_form_value("#api-key-form select[name='api_key[ttl_days]']", "7")
    |> click_button("Generate API key")
    |> assert_has("#generated-api-key", text: "jidomanagedagents")
    |> refute_has("body", text: "YOUR_API_KEY")
    |> assert_has("body", text: "x-api-key: jidomanagedagents")
    |> click_button("Environments")
    |> assert_has("body", text: "/v1/environments")
    |> assert_has("body", text: "Restricted Demo Sandbox")
  end

  test "openapi json and swagger ui routes render from the docs links", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit_live(~p"/console/api-docs")
    |> click_link("a[href='/api/json/open_api']", "Open OpenAPI JSON")
    |> assert_path("/api/json/open_api")
    |> evaluate("document.body.innerText", fn text ->
      assert text =~ "openapi"
      assert text =~ "Jido Managed Agents /v1 API"
      assert text =~ "/v1/agents"
    end)
    |> visit("/api/json/swaggerui")
    |> assert_path("/api/json/swaggerui")
    |> assert_has("title", text: "Swagger UI")
    |> assert_has("body", text: "Jido Managed Agents /v1 API")
    |> assert_has("body", text: "/v1/agents")
  end
end
