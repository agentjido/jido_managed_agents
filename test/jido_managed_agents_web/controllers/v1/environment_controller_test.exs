defmodule JidoManagedAgentsWeb.V1.EnvironmentControllerTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "GET /v1/environments rejects requests without x-api-key", %{conn: conn} do
    conn =
      conn
      |> Helpers.json_conn()
      |> get(~p"/v1/environments")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "POST /v1/environments creates a reusable environment template", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/environments", %{
        "name" => "Shared Runtime Template",
        "description" => "Local runtime template using Anthropic-compatible fields.",
        "config" => %{
          "type" => "cloud",
          "networking" => %{"type" => "unrestricted"}
        },
        "metadata" => %{"team" => "platform"}
      })

    assert %{
             "id" => environment_id,
             "type" => "environment",
             "name" => "Shared Runtime Template",
             "description" => "Local runtime template using Anthropic-compatible fields.",
             "config" => %{
               "type" => "cloud",
               "networking" => %{"type" => "unrestricted"}
             },
             "metadata" => %{"team" => "platform"},
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 201)

    assert environment_id
    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "POST /v1/environments rejects invalid config values and unsupported fields", _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    cases = [
      {%{
         "name" => "invalid-type",
         "config" => %{"type" => "local", "networking" => %{"type" => "restricted"}}
       }, "config.type must be \"cloud\"."},
      {%{
         "name" => "invalid-networking",
         "config" => %{"type" => "cloud", "networking" => %{"type" => "isolated"}}
       }, "config.networking.type must be \"restricted\" or \"unrestricted\"."},
      {%{
         "name" => "unsupported-field",
         "config" => %{
           "type" => "cloud",
           "networking" => %{"type" => "restricted"},
           "storage" => %{"type" => "ephemeral"}
         }
       }, "config.storage is not supported in v1."}
    ]

    Enum.each(cases, fn {payload, expected_message} ->
      conn =
        build_conn()
        |> Helpers.authorized_conn(owner_api_key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/environments", payload)

      assert json_response(conn, 400) == %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => expected_message
               }
             }
    end)
  end

  test "GET /v1/environments returns newest first, excludes archived environments, and isolates users",
       %{
         conn: conn
       } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    oldest = Helpers.create_environment!(owner, %{name: "oldest-environment"})
    Process.sleep(1)
    archived = Helpers.create_environment!(owner, %{name: "archived-environment"})
    Process.sleep(1)
    newest = Helpers.create_environment!(owner, %{name: "newest-environment"})
    Helpers.archive_environment!(owner, archived)

    other = Helpers.create_user!()
    Helpers.create_environment!(other, %{name: "other-environment"})

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/environments")

    assert %{
             "data" => [
               %{"id" => newest_id, "type" => "environment"},
               %{"id" => oldest_id, "type" => "environment"}
             ],
             "has_more" => false
           } = json_response(conn, 200)

    assert newest_id == newest.id
    assert oldest_id == oldest.id
    refute newest_id == archived.id
    refute oldest_id == archived.id
  end

  test "GET /v1/environments/:id returns the persisted environment shape", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    environment =
      Helpers.create_environment!(owner, %{
        name: "owner-environment",
        description: "Environment for retrieval tests",
        config: %{
          "type" => "cloud",
          "networking" => %{"type" => "restricted"}
        },
        metadata: %{"scope" => "show-test"}
      })

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/environments/#{environment.id}")

    assert %{
             "id" => environment_id,
             "type" => "environment",
             "name" => "owner-environment",
             "description" => "Environment for retrieval tests",
             "config" => %{
               "type" => "cloud",
               "networking" => %{"type" => "restricted"}
             },
             "metadata" => %{"scope" => "show-test"},
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 200)

    assert environment_id == environment.id
    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "PUT /v1/environments/:id updates mutable fields and preserves omitted ones", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    environment =
      Helpers.create_environment!(owner, %{
        name: "stable-template",
        description: "Original description",
        config: %{
          "type" => "cloud",
          "networking" => %{"type" => "restricted"}
        },
        metadata: %{"team" => "platform"}
      })

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/environments/#{environment.id}", %{
        "description" => "Updated description",
        "config" => %{
          "type" => "cloud",
          "networking" => %{"type" => "unrestricted"}
        }
      })

    assert %{
             "id" => environment_id,
             "name" => "stable-template",
             "description" => "Updated description",
             "config" => %{
               "type" => "cloud",
               "networking" => %{"type" => "unrestricted"}
             },
             "metadata" => %{"team" => "platform"},
             "archived_at" => nil
           } = json_response(conn, 200)

    assert environment_id == environment.id
  end

  test "POST /v1/environments/:id/archive marks the environment archived and future updates are rejected",
       %{
         conn: conn
       } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    environment = Helpers.create_environment!(owner, %{name: "archive-me"})

    archive_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> post(~p"/v1/environments/#{environment.id}/archive")

    assert %{
             "id" => environment_id,
             "archived_at" => archived_at
           } = json_response(archive_conn, 200)

    assert environment_id == environment.id
    assert is_binary(archived_at)

    update_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/environments/#{environment.id}", %{
        "description" => "should fail"
      })

    assert json_response(update_conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "Archived environments are read-only."
             }
           }
  end

  test "DELETE /v1/environments/:id rejects environments with dependent sessions", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    environment = Helpers.create_environment!(owner, %{name: "session-bound-environment"})
    agent = Helpers.create_agent!(owner, %{name: "environment-session-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    workspace = Helpers.create_workspace!(owner, agent)
    Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    delete_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/environments/#{environment.id}")

    assert json_response(delete_conn, 409) == %{
             "error" => %{
               "type" => "conflict_error",
               "message" => "Cannot delete an environment that has dependent sessions."
             }
           }
  end

  test "DELETE /v1/environments/:id deletes environments that have no dependent sessions",
       %{
         conn: conn
       } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    environment = Helpers.create_environment!(owner, %{name: "deletable-environment"})

    delete_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/environments/#{environment.id}")

    assert response(delete_conn, 204) == ""

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/environments/#{environment.id}")

    assert json_response(show_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end
end
