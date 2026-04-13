defmodule JidoManagedAgentsWeb.ResourceFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureFixtures
  import JidoManagedAgentsWeb.FeatureHelpers

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "vault flows keep created and rotated secrets write-only", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    vault_name = "Product Ops Vault"
    access_token = "lin_api_#{System.unique_integer([:positive])}"

    session =
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/vaults")
      |> assert_has("h1", text: "Vaults & Credentials")
      |> click_button("New Vault")
      |> assert_has("#vault-form")
      |> fill_in("#vault_name", "Name", with: vault_name)
      |> fill_in("#vault_description", "Description", with: "Third-party service credentials")
      |> set_form_value(
        "#vault-form textarea[name='vault[metadata_json]']",
        ~s({"external_user_id":"usr_abc123"})
      )
      |> click_button("#vault-save-button", "Create Vault")
      |> assert_has("body", text: "Secrets are write-only. Stored values cannot be retrieved.")

    vault = get_vault_by_name!(user, vault_name)

    session =
      session
      |> assert_path(~p"/console/vaults/#{vault.id}")
      |> assert_has("body", text: "Secrets are write-only. Stored values cannot be retrieved.")
      |> click_button("#show-credential-form-button", "Add Credential")
      |> fill_in("#credential_display_name", "Display Name", with: "Linear API key")
      |> set_form_value("#credential-form select[name='credential[type]']", "static_bearer")
      |> fill_in(
        "#credential_mcp_server_url",
        "MCP Server URL",
        with: "https://mcp.linear.app/mcp"
      )
      |> set_form_value("#credential-form input[name='credential[token]']", access_token)
      |> set_form_value(
        "#credential-form textarea[name='credential[metadata_json]']",
        ~s({"provider":"linear"})
      )
      |> click_button("#credential-save-button", "Create Credential")

    session
    |> assert_has("#credential-list", text: "Linear API key")
    |> refute_has("body", text: access_token)
  end

  test "oauth rotation keeps routing fields fixed while updating write-only values", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    rotated_access_token = "new-access-#{System.unique_integer([:positive])}"

    vault = Helpers.create_vault!(user, %{name: "Slack Vault"})

    credential =
      Helpers.create_credential!(user, vault,
        type: :mcp_oauth,
        mcp_server_url: "https://mcp.slack.com/mcp",
        token_endpoint: "https://slack.com/api/oauth.v2.access",
        client_id: "client-123",
        access_token: "old-access",
        metadata: %{"provider" => "slack"}
      )

    session =
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/vaults/#{vault.id}/credentials/#{credential.id}/rotate")
      |> assert_has("body", text: "Locked routing fields")
      |> assert_has(
        "#credential_token_endpoint[disabled]",
        value: "https://slack.com/api/oauth.v2.access"
      )
      |> assert_has("#credential_client_id[disabled]", value: "client-123")
      |> set_form_value(
        "#credential-form input[name='credential[access_token]']",
        rotated_access_token
      )
      |> click_button("#credential-save-button", "Rotate Credential")

    session
    |> assert_path(~p"/console/vaults/#{vault.id}")
    |> refute_has("body", text: rotated_access_token)
  end

  test "environments can be created, archived, and filtered", %{conn: conn} do
    credentials = create_password_user!()
    user = credentials.user
    environment_name = "Delivery Sandbox"

    session =
      conn
      |> sign_in(credentials)
      |> visit_live(~p"/console/environments")
      |> assert_has("h1", text: "Environments")
      |> fill_in("#environment_name", "Name", with: environment_name)
      |> fill_in(
        "#environment_description",
        "Description",
        with: "Reusable runtime for browser coverage"
      )
      |> set_form_value(
        "#environment-form select[name='environment[networking_type]']",
        "unrestricted"
      )
      |> set_form_value(
        "#environment-form textarea[name='environment[metadata_json]']",
        ~s({"team":"ops"})
      )
      |> click_button("#environment-save-button", "Create Template")

    environment = get_environment_by_name!(user, environment_name)

    session =
      session
      |> assert_path(~p"/console/environments/#{environment.id}/edit")
      |> assert_has("body", text: "Edit: Delivery Sandbox")
      |> click_button("#environment-archive-button", "Archive")
      |> assert_has("#environment-read-only-note", text: "read-only")
      |> click_button("Archived")
      |> assert_has("#environment-card-#{environment.id}", text: environment_name)
      |> click_button("Active")

    session
    |> refute_has("#environment-card-#{environment.id}")
  end
end
