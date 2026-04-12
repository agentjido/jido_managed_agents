defmodule JidoManagedAgentsWeb.ResourceConsoleLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.CredentialDefinition
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "requires an authenticated user for resource pages", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/environments")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/vaults")
  end

  test "environment page renders, isolates users, and saves templates", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    owner_environment =
      Helpers.create_environment!(user, %{
        name: "Ops Sandbox",
        description: "Existing owner environment"
      })

    other = Helpers.create_user!()
    Helpers.create_environment!(other, %{name: "Other User Environment"})

    {:ok, view, html} = live(conn, ~p"/console/environments")

    assert html =~ "Environments"
    assert html =~ owner_environment.name
    refute html =~ "Other User Environment"
    assert has_element?(view, "#environment-form")

    render_submit(element(view, "#environment-form"), %{
      "environment" => environment_params("Delivery Sandbox")
    })

    created_environment = get_environment_by_name!(user, "Delivery Sandbox")

    assert_patch(view, ~p"/console/environments/#{created_environment.id}/edit")

    {:ok, edit_view, edit_html} =
      live(conn, ~p"/console/environments/#{created_environment.id}/edit")

    assert edit_html =~ "Edit: Delivery Sandbox"

    render_submit(element(edit_view, "#environment-form"), %{
      "environment" =>
        environment_params("Delivery Sandbox", %{
          "description" => "Updated delivery template",
          "networking_type" => "unrestricted",
          "metadata_json" => ~s({"team":"platform","tier":"prod"})
        })
    })

    updated_environment = get_environment_by_name!(user, "Delivery Sandbox")

    assert updated_environment.description == "Updated delivery template"
    assert get_in(updated_environment.config, ["networking", "type"]) == "unrestricted"
    assert updated_environment.metadata == %{"team" => "platform", "tier" => "prod"}
  end

  test "vault page creates vaults and static credentials with explicit write-only behavior", %{
    conn: conn
  } do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    other = Helpers.create_user!()
    Helpers.create_vault!(other, %{name: "Other User Vault"})

    {:ok, view, html} = live(conn, ~p"/console/vaults")

    assert html =~ "Vaults"
    refute html =~ "Other User Vault"

    render_click(element(view, "button[phx-click='toggle_create_vault']"))

    render_submit(element(view, "#vault-form"), %{
      "vault" => vault_params("Alice Vault")
    })

    vault = get_vault_by_name!(user, "Alice Vault")

    assert_patch(view, ~p"/console/vaults/#{vault.id}")
    assert render(view) =~ "Secrets are write-only. Stored values cannot be retrieved."

    access_token = "lin_api_#{System.unique_integer([:positive])}"

    render_click(element(view, "#show-credential-form-button"))

    render_submit(element(view, "#credential-form"), %{
      "credential" => static_credential_params("Linear API key", access_token)
    })

    credential = get_credential_by_url!(user, vault, "https://mcp.linear.app/mcp")

    assert credential.type == :static_bearer
    assert render(view) =~ "Linear API key"
    refute render(view) =~ access_token

    loaded_credential =
      Ash.load!(credential, [:access_token], actor: user, domain: Integrations)

    assert loaded_credential.access_token == access_token
  end

  test "vault page rotates oauth credentials and preserves immutable fields", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    vault = Helpers.create_vault!(user, %{name: "Slack Vault"})

    credential =
      Helpers.create_credential!(user, vault,
        type: :mcp_oauth,
        mcp_server_url: "https://mcp.slack.com/mcp",
        token_endpoint: "https://slack.com/api/oauth.v2.access",
        client_id: "client-123",
        access_token: "old-access",
        refresh_token: "old-refresh",
        client_secret: "old-secret",
        metadata: %{"provider" => "slack"}
      )

    {:ok, view, html} =
      live(conn, ~p"/console/vaults/#{vault.id}/credentials/#{credential.id}/rotate")

    assert html =~ "Locked routing fields"
    assert html =~ "leave blank to keep current"

    render_submit(element(view, "#credential-form"), %{
      "credential" =>
        oauth_rotation_params(%{
          "display_name" => "Slack Rotation",
          "access_token" => "new-access",
          "expires_at" => "2026-05-15T00:00:00Z",
          "refresh_token" => "new-refresh",
          "refresh_scope" => "channels:history",
          "token_endpoint_auth_type" => "client_secret_post",
          "client_secret" => "new-secret",
          "metadata_json" => ~s({"provider":"slack","team":"platform"})
        })
    })

    updated_credential =
      get_credential_by_url!(user, vault, "https://mcp.slack.com/mcp")
      |> Ash.load!([:access_token, :refresh_token, :client_secret],
        actor: user,
        domain: Integrations
      )

    serialized = CredentialDefinition.serialize_credential(updated_credential)
    auth = serialized.auth
    refresh = Map.get(auth, :refresh, %{})

    assert updated_credential.mcp_server_url == "https://mcp.slack.com/mcp"
    assert updated_credential.token_endpoint == "https://slack.com/api/oauth.v2.access"
    assert updated_credential.client_id == "client-123"
    assert updated_credential.access_token == "new-access"
    assert updated_credential.refresh_token == "new-refresh"
    assert updated_credential.client_secret == "new-secret"
    assert serialized.metadata == %{"provider" => "slack", "team" => "platform"}
    assert auth.expires_at == "2026-05-15T00:00:00Z"
    assert refresh.scope == "channels:history"
    refute render(view) =~ "new-access"
    refute render(view) =~ "new-refresh"
    refute render(view) =~ "new-secret"
  end

  defp environment_params(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "description" => "Reusable runtime for console tests",
        "networking_type" => "restricted",
        "metadata_json" => ~s({"team":"ops"})
      },
      overrides
    )
  end

  defp vault_params(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "description" => "Third-party service credentials",
        "metadata_json" => ~s({"external_user_id":"usr_abc123"})
      },
      overrides
    )
  end

  defp static_credential_params(name, token, overrides \\ %{}) do
    Map.merge(
      %{
        "display_name" => name,
        "type" => "static_bearer",
        "mcp_server_url" => "https://mcp.linear.app/mcp",
        "token" => token,
        "metadata_json" => ~s({"provider":"linear"})
      },
      overrides
    )
  end

  defp oauth_rotation_params(overrides) do
    Map.merge(
      %{
        "display_name" => "Slack Rotation",
        "type" => "mcp_oauth",
        "mcp_server_url" => "https://mcp.slack.com/mcp",
        "access_token" => "",
        "expires_at" => "",
        "refresh_token" => "",
        "refresh_scope" => "",
        "token_endpoint_auth_type" => "client_secret_post",
        "client_secret" => "",
        "metadata_json" => ~s({"provider":"slack"})
      },
      overrides
    )
  end

  defp get_environment_by_name!(user, name) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end

  defp get_vault_by_name!(user, name) do
    Vault
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end

  defp get_credential_by_url!(user, vault, url) do
    Credential
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
    |> Ash.Query.filter(vault_id == ^vault.id and mcp_server_url == ^url)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read_one!()
  end
end
