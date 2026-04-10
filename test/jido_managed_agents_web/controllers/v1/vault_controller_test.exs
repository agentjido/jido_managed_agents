defmodule JidoManagedAgentsWeb.V1.VaultControllerTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Repo
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "GET /v1/vaults rejects requests without x-api-key", %{conn: conn} do
    conn =
      conn
      |> Helpers.json_conn()
      |> get(~p"/v1/vaults")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "POST /v1/vaults creates a per-user vault and GET /v1/vaults/:id returns it", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults", %{
        "display_name" => "Alice",
        "description" => "Third-party service credentials",
        "display_metadata" => %{"label" => "Primary"},
        "metadata" => %{"external_user_id" => "usr_abc123"}
      })

    assert %{
             "id" => vault_id,
             "type" => "vault",
             "name" => "Alice",
             "display_name" => "Alice",
             "description" => "Third-party service credentials",
             "display_metadata" => %{"label" => "Primary", "display_name" => "Alice"},
             "metadata" => %{"external_user_id" => "usr_abc123"},
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(create_conn, 201)

    assert is_binary(vault_id)
    assert is_binary(created_at)
    assert is_binary(updated_at)

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{vault_id}")

    assert %{
             "id" => ^vault_id,
             "type" => "vault",
             "display_name" => "Alice",
             "metadata" => %{"external_user_id" => "usr_abc123"}
           } = json_response(show_conn, 200)
  end

  test "GET /v1/vaults returns newest first and isolates users", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    oldest = Helpers.create_vault!(owner, %{name: "oldest-vault"})
    Process.sleep(1)
    newest = Helpers.create_vault!(owner, %{name: "newest-vault"})

    other = Helpers.create_user!()
    Helpers.create_vault!(other, %{name: "other-vault"})

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults")

    assert %{
             "data" => [
               %{"id" => newest_id, "type" => "vault"},
               %{"id" => oldest_id, "type" => "vault"}
             ],
             "has_more" => false
           } = json_response(conn, 200)

    assert newest_id == newest.id
    assert oldest_id == oldest.id
  end

  test "POST /v1/vaults/:vault_id/credentials creates mcp_oauth credentials with encrypted secrets and write-only responses",
       %{
         conn: conn
       } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    vault = Helpers.create_vault!(owner, %{name: "oauth-vault"})
    access_token = "xoxp-#{System.unique_integer([:positive])}"
    refresh_token = "xoxe-1-#{System.unique_integer([:positive])}"
    client_secret = "secret-#{System.unique_integer([:positive])}"
    mcp_server_url = "https://mcp.slack.com/mcp"
    token_endpoint = "https://slack.com/api/oauth.v2.access"
    client_id = "1234567890.0987654321"

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults/#{vault.id}/credentials", %{
        "display_name" => "Alice's Slack",
        "metadata" => %{"provider" => "slack"},
        "auth" => %{
          "type" => "mcp_oauth",
          "mcp_server_url" => mcp_server_url,
          "access_token" => access_token,
          "expires_at" => "2026-04-15T00:00:00Z",
          "refresh" => %{
            "token_endpoint" => token_endpoint,
            "client_id" => client_id,
            "scope" => "channels:read chat:write",
            "refresh_token" => refresh_token,
            "token_endpoint_auth" => %{
              "type" => "client_secret_post",
              "client_secret" => client_secret
            }
          }
        }
      })

    assert %{
             "id" => credential_id,
             "type" => "credential",
             "vault_id" => vault_id,
             "display_name" => "Alice's Slack",
             "metadata" => %{"provider" => "slack"},
             "auth" => %{
               "type" => "mcp_oauth",
               "mcp_server_url" => ^mcp_server_url,
               "expires_at" => "2026-04-15T00:00:00Z",
               "refresh" => %{
                 "token_endpoint" => ^token_endpoint,
                 "client_id" => ^client_id,
                 "scope" => "channels:read chat:write",
                 "token_endpoint_auth" => %{"type" => "client_secret_post"}
               }
             }
           } = json_response(create_conn, 201)

    assert vault_id == vault.id

    refute create_conn.resp_body =~ access_token
    refute create_conn.resp_body =~ refresh_token
    refute create_conn.resp_body =~ client_secret

    assert %{
             rows: [
               [
                 "mcp_oauth",
                 ^mcp_server_url,
                 ^token_endpoint,
                 ^client_id,
                 encrypted_access_token,
                 encrypted_refresh_token,
                 encrypted_client_secret
               ]
             ]
           } =
             Repo.query!(
               """
               SELECT type, mcp_server_url, token_endpoint, client_id,
                      encrypted_access_token, encrypted_refresh_token, encrypted_client_secret
               FROM credentials
               WHERE id = $1
               """,
               [dump_uuid!(credential_id)]
             )

    assert is_binary(encrypted_access_token)
    assert is_binary(encrypted_refresh_token)
    assert is_binary(encrypted_client_secret)
    refute encrypted_access_token == access_token
    refute encrypted_refresh_token == refresh_token
    refute encrypted_client_secret == client_secret

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{vault.id}/credentials/#{credential_id}")

    assert %{
             "id" => ^credential_id,
             "auth" => %{
               "type" => "mcp_oauth",
               "mcp_server_url" => ^mcp_server_url
             }
           } = json_response(show_conn, 200)

    refute show_conn.resp_body =~ access_token
    refute show_conn.resp_body =~ refresh_token
    refute show_conn.resp_body =~ client_secret
  end

  test "static_bearer credential list is write-only and isolated per user", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    owner_vault = Helpers.create_vault!(owner, %{name: "owner-vault"})

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults/#{owner_vault.id}/credentials", %{
        "display_name" => "Linear API key",
        "metadata" => %{"provider" => "linear"},
        "auth" => %{
          "type" => "static_bearer",
          "mcp_server_url" => "https://mcp.linear.app/mcp",
          "token" => "lin_api_#{System.unique_integer([:positive])}"
        }
      })

    assert %{
             "id" => credential_id,
             "display_name" => "Linear API key",
             "auth" => %{
               "type" => "static_bearer",
               "mcp_server_url" => "https://mcp.linear.app/mcp"
             }
           } = json_response(create_conn, 201)

    refute create_conn.resp_body =~ "lin_api_"

    other = Helpers.create_user!()
    other_vault = Helpers.create_vault!(other, %{name: "other-vault"})

    Helpers.create_credential!(other, other_vault,
      type: :static_bearer,
      mcp_server_url: "https://mcp.other.example/mcp",
      access_token: "other-secret"
    )

    list_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{owner_vault.id}/credentials")

    assert %{
             "data" => [
               %{
                 "id" => ^credential_id,
                 "type" => "credential",
                 "display_name" => "Linear API key",
                 "metadata" => %{"provider" => "linear"},
                 "auth" => %{
                   "type" => "static_bearer",
                   "mcp_server_url" => "https://mcp.linear.app/mcp"
                 }
               }
             ],
             "has_more" => false
           } = json_response(list_conn, 200)

    other_list_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{other_vault.id}/credentials")

    assert json_response(other_list_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  test "PUT /v1/vaults/:vault_id/credentials/:id rotates mutable secrets and preserves immutable fields",
       %{
         conn: conn
       } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    vault = Helpers.create_vault!(owner, %{name: "rotate-vault"})

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults/#{vault.id}/credentials", %{
        "display_name" => "Slack Rotation",
        "metadata" => %{"provider" => "slack"},
        "auth" => %{
          "type" => "mcp_oauth",
          "mcp_server_url" => "https://mcp.slack.com/mcp",
          "access_token" => "old-access",
          "expires_at" => "2026-04-15T00:00:00Z",
          "refresh" => %{
            "token_endpoint" => "https://slack.com/api/oauth.v2.access",
            "client_id" => "client-123",
            "refresh_token" => "old-refresh",
            "token_endpoint_auth" => %{
              "type" => "client_secret_post",
              "client_secret" => "old-secret"
            }
          }
        }
      })

    credential_id = json_response(create_conn, 201)["id"]

    rotate_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/vaults/#{vault.id}/credentials/#{credential_id}", %{
        "metadata" => %{"team" => "platform"},
        "auth" => %{
          "type" => "mcp_oauth",
          "access_token" => "new-access",
          "expires_at" => "2026-05-15T00:00:00Z",
          "refresh" => %{
            "refresh_token" => "new-refresh",
            "scope" => "channels:history",
            "token_endpoint_auth" => %{
              "type" => "client_secret_post",
              "client_secret" => "new-secret"
            }
          }
        }
      })

    assert %{
             "id" => ^credential_id,
             "display_name" => "Slack Rotation",
             "metadata" => %{"provider" => "slack", "team" => "platform"},
             "auth" => %{
               "type" => "mcp_oauth",
               "mcp_server_url" => "https://mcp.slack.com/mcp",
               "expires_at" => "2026-05-15T00:00:00Z",
               "refresh" => %{
                 "token_endpoint" => "https://slack.com/api/oauth.v2.access",
                 "client_id" => "client-123",
                 "scope" => "channels:history",
                 "token_endpoint_auth" => %{"type" => "client_secret_post"}
               }
             }
           } = json_response(rotate_conn, 200)

    refute rotate_conn.resp_body =~ "new-access"
    refute rotate_conn.resp_body =~ "new-refresh"
    refute rotate_conn.resp_body =~ "new-secret"

    loaded_credential =
      Credential
      |> Ash.Query.for_read(:by_id, %{id: credential_id}, actor: owner, domain: Integrations)
      |> Ash.read_one!()
      |> Ash.load!([:access_token, :refresh_token, :client_secret],
        actor: owner,
        domain: Integrations
      )

    assert loaded_credential.mcp_server_url == "https://mcp.slack.com/mcp"
    assert loaded_credential.token_endpoint == "https://slack.com/api/oauth.v2.access"
    assert loaded_credential.client_id == "client-123"
    assert loaded_credential.access_token == "new-access"
    assert loaded_credential.refresh_token == "new-refresh"
    assert loaded_credential.client_secret == "new-secret"
  end

  test "PUT /v1/vaults/:vault_id/credentials/:id rejects immutable auth fields", _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    vault = Helpers.create_vault!(owner, %{name: "immutable-vault"})

    credential =
      Helpers.create_credential!(owner, vault,
        type: :mcp_oauth,
        mcp_server_url: "https://mcp.slack.com/mcp",
        token_endpoint: "https://slack.com/api/oauth.v2.access",
        client_id: "client-123",
        access_token: "old-access",
        refresh_token: "old-refresh",
        client_secret: "old-secret"
      )

    cases = [
      {%{"auth" => %{"type" => "mcp_oauth", "mcp_server_url" => "https://changed.example/mcp"}},
       "auth.mcp_server_url cannot be changed after credential creation."},
      {%{
         "auth" => %{
           "type" => "mcp_oauth",
           "refresh" => %{"token_endpoint" => "https://changed.example/token"}
         }
       }, "auth.refresh.token_endpoint cannot be changed after credential creation."},
      {%{"auth" => %{"type" => "mcp_oauth", "refresh" => %{"client_id" => "new-client"}}},
       "auth.refresh.client_id cannot be changed after credential creation."}
    ]

    Enum.each(cases, fn {payload, expected_message} ->
      conn =
        build_conn()
        |> Helpers.authorized_conn(owner_api_key)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/v1/vaults/#{vault.id}/credentials/#{credential.id}", payload)

      assert json_response(conn, 400) == %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => expected_message
               }
             }
    end)
  end

  test "DELETE credential and vault endpoints remove records and preserve isolation", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    vault = Helpers.create_vault!(owner, %{name: "delete-vault"})

    credential =
      Helpers.create_credential!(owner, vault,
        type: :static_bearer,
        mcp_server_url: "https://mcp.linear.app/mcp",
        access_token: "delete-me"
      )

    delete_credential_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/vaults/#{vault.id}/credentials/#{credential.id}")

    assert response(delete_credential_conn, 204) == ""

    show_deleted_credential_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{vault.id}/credentials/#{credential.id}")

    assert json_response(show_deleted_credential_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }

    credential_to_cascade =
      Helpers.create_credential!(owner, vault,
        type: :static_bearer,
        mcp_server_url: "https://mcp.linear.app/secondary",
        access_token: "cascade-me"
      )

    other = Helpers.create_user!()
    other_vault = Helpers.create_vault!(other, %{name: "other-vault"})

    other_credential =
      Helpers.create_credential!(other, other_vault,
        type: :static_bearer,
        mcp_server_url: "https://mcp.other.example/mcp",
        access_token: "other-secret"
      )

    delete_vault_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/vaults/#{vault.id}")

    assert response(delete_vault_conn, 204) == ""

    assert Repo.query!(
             "SELECT count(*) FROM credentials WHERE id IN ($1, $2)",
             [dump_uuid!(credential.id), dump_uuid!(credential_to_cascade.id)]
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM credentials WHERE id = $1",
             [dump_uuid!(other_credential.id)]
           ).rows == [[1]]

    show_vault_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/vaults/#{vault.id}")

    assert json_response(show_vault_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }

    other_delete_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/vaults/#{other_vault.id}")

    assert json_response(other_delete_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
