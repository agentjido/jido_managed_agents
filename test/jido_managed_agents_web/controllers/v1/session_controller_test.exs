defmodule JidoManagedAgentsWeb.V1.SessionControllerTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.{SessionEvent, SessionEventLog, SessionThread, SessionThreads}
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "GET /v1/sessions rejects requests without x-api-key", %{conn: conn} do
    conn =
      conn
      |> Helpers.json_conn()
      |> get(~p"/v1/sessions")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "GET /v1/sessions/:id/stream rejects requests without x-api-key", %{conn: conn} do
    session_owner = Helpers.create_user!()
    agent = Helpers.create_agent!(session_owner, %{name: "stream-auth-agent"})
    agent_version = Helpers.latest_agent_version!(session_owner, agent)
    environment = Helpers.create_environment!(session_owner)
    workspace = Helpers.create_workspace!(session_owner, agent)
    session = Helpers.create_session!(session_owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{session.id}/stream")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "POST /v1/sessions resolves the latest agent version, auto-selects a workspace, and preserves vault order",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "planner"})
    _version_two = Helpers.create_agent_version!(owner, agent, %{version: 2})
    environment = Helpers.create_environment!(owner)
    vault_one = Helpers.create_vault!(owner, %{name: "vault-one"})
    vault_two = Helpers.create_vault!(owner, %{name: "vault-two"})

    assert Helpers.workspace_for!(owner, agent) == nil

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id,
        "title" => "Session A",
        "vault_ids" => [vault_two.id, vault_one.id]
      })

    assert %{
             "id" => session_id,
             "type" => "session",
             "agent" => %{"type" => "agent", "id" => agent_id, "version" => 2},
             "environment_id" => environment_id,
             "vault_ids" => [vault_two_id, vault_one_id],
             "title" => "Session A",
             "status" => "idle",
             "stop_reason" => nil,
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 201)

    session = Helpers.get_session!(owner, session_id, [:session_vaults])
    workspace = Helpers.workspace_for!(owner, agent)
    latest_version = Helpers.latest_agent_version!(owner, agent)

    assert agent_id == agent.id
    assert environment_id == environment.id
    assert vault_two_id == vault_two.id
    assert vault_one_id == vault_one.id
    assert session.workspace_id == workspace.id
    assert session.agent_version_id == latest_version.id

    assert Enum.map(session.session_vaults, &{&1.position, &1.vault_id}) == [
             {0, vault_two.id},
             {1, vault_one.id}
           ]

    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "POST /v1/sessions accepts a pinned agent version object", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "researcher"})
    version_one = Helpers.latest_agent_version!(owner, agent)
    _version_two = Helpers.create_agent_version!(owner, agent, %{version: 2})
    environment = Helpers.create_environment!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => %{"type" => "agent", "id" => agent.id, "version" => 1},
        "environment_id" => environment.id
      })

    assert %{
             "id" => session_id,
             "agent" => %{"type" => "agent", "id" => agent_id, "version" => 1},
             "environment_id" => environment_id,
             "vault_ids" => [],
             "status" => "idle"
           } = json_response(conn, 201)

    session = Helpers.get_session!(owner, session_id)

    assert agent_id == agent.id
    assert environment_id == environment.id
    assert session.agent_version_id == version_one.id
  end

  test "POST /v1/sessions allows exactly 20 total skills across the callable agent graph",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    callable_agent =
      Helpers.create_agent!(owner, %{name: "delegate-allowed", with_version: false})

    Helpers.create_agent_version!(owner, callable_agent, %{
      version: 1,
      agent_version_skills: build_skill_links(owner, "callable-allowed", 10)
    })

    root_agent = Helpers.create_agent!(owner, %{name: "planner-allowed", with_version: false})

    root_version =
      Helpers.create_agent_version!(owner, root_agent, %{
        version: 1,
        agent_version_skills: build_skill_links(owner, "root-allowed", 10),
        agent_version_callable_agents: [
          callable_agent_link(owner, callable_agent, 0, 1)
        ]
      })

    environment = Helpers.create_environment!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => root_agent.id,
        "environment_id" => environment.id
      })

    assert %{
             "id" => session_id,
             "agent" => %{"type" => "agent", "id" => agent_id, "version" => 1},
             "environment_id" => environment_id,
             "status" => "idle"
           } = json_response(conn, 201)

    session = Helpers.get_session!(owner, session_id)

    assert agent_id == root_agent.id
    assert environment_id == environment.id
    assert session.agent_version_id == root_version.id
  end

  test "POST /v1/sessions rejects more than 20 total skills and resolves unpinned callable agents to the latest version",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    callable_agent = Helpers.create_agent!(owner, %{name: "delegate-latest", with_version: false})

    Helpers.create_agent_version!(owner, callable_agent, %{
      version: 1,
      agent_version_skills: build_skill_links(owner, "callable-v1", 1)
    })

    Helpers.create_agent_version!(owner, callable_agent, %{
      version: 2,
      agent_version_skills: build_skill_links(owner, "callable-v2", 11)
    })

    root_agent = Helpers.create_agent!(owner, %{name: "planner-latest", with_version: false})

    Helpers.create_agent_version!(owner, root_agent, %{
      version: 1,
      agent_version_skills: build_skill_links(owner, "root-latest", 10),
      agent_version_callable_agents: [
        callable_agent_link(owner, callable_agent, 0, nil)
      ]
    })

    environment = Helpers.create_environment!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => root_agent.id,
        "environment_id" => environment.id
      })

    assert json_response(conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" =>
                 "sessions support at most 20 total skills across all agents; resolved 21."
             }
           }
  end

  test "POST /v1/sessions rejects explicit workspace selection and cross-user vaults", _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)

    other = Helpers.create_user!()
    other_vault = Helpers.create_vault!(other)

    workspace_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id,
        "workspace_id" => workspace.id
      })

    assert json_response(workspace_conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "workspace_id is not supported in v1 session creation."
             }
           }

    vault_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id,
        "vault_ids" => [other_vault.id]
      })

    assert json_response(vault_conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "vault #{other_vault.id} was not found."
             }
           }
  end

  test "POST /v1/sessions rejects a second active session on the same workspace", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner)
    environment = Helpers.create_environment!(owner)

    first_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id
      })

    assert %{"status" => "idle"} = json_response(first_conn, 201)

    conflict_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id
      })

    assert json_response(conflict_conn, 409) == %{
             "error" => %{
               "type" => "conflict_error",
               "message" => "workspace already has an active session"
             }
           }
  end

  test "GET /v1/sessions returns newest first, excludes deleted sessions, and isolates users", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    environment = Helpers.create_environment!(owner)

    oldest_agent = Helpers.create_agent!(owner, %{name: "oldest"})
    oldest_workspace = Helpers.create_workspace!(owner, oldest_agent)
    oldest_version = Helpers.latest_agent_version!(owner, oldest_agent)

    oldest =
      Helpers.create_session!(owner, oldest_agent, oldest_version, environment, oldest_workspace)

    Process.sleep(1)

    deleted_agent = Helpers.create_agent!(owner, %{name: "deleted"})
    deleted_workspace = Helpers.create_workspace!(owner, deleted_agent)
    deleted_version = Helpers.latest_agent_version!(owner, deleted_agent)

    deleted =
      Helpers.create_session!(
        owner,
        deleted_agent,
        deleted_version,
        environment,
        deleted_workspace
      )

    Process.sleep(1)

    newest_agent = Helpers.create_agent!(owner, %{name: "newest"})
    newest_workspace = Helpers.create_workspace!(owner, newest_agent)
    newest_version = Helpers.latest_agent_version!(owner, newest_agent)

    newest =
      Helpers.create_session!(owner, newest_agent, newest_version, environment, newest_workspace)

    other = Helpers.create_user!()
    other_agent = Helpers.create_agent!(other, %{name: "other"})
    other_environment = Helpers.create_environment!(other)
    other_workspace = Helpers.create_workspace!(other, other_agent)
    other_version = Helpers.latest_agent_version!(other, other_agent)

    _other_session =
      Helpers.create_session!(
        other,
        other_agent,
        other_version,
        other_environment,
        other_workspace
      )

    delete_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/sessions/#{deleted.id}")

    assert response(delete_conn, 204)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions")

    assert %{
             "data" => [
               %{"id" => newest_id, "type" => "session"},
               %{"id" => oldest_id, "type" => "session"}
             ],
             "has_more" => false
           } = json_response(conn, 200)

    assert newest_id == newest.id
    assert oldest_id == oldest.id
    refute newest_id == deleted.id
    refute oldest_id == deleted.id
  end

  test "GET /v1/sessions/:id returns the session shape and blocks cross-user access", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner)
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    vault = Helpers.create_vault!(owner)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    session =
      session
      |> Ash.Changeset.for_update(
        :update,
        %{title: "Existing Session"},
        actor: owner,
        domain: Sessions
      )
      |> Ash.update!()

    create_session_vault!(owner, session.id, vault.id, 0)

    show_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session.id}")

    assert %{
             "id" => session_id,
             "type" => "session",
             "agent" => %{"type" => "agent", "id" => agent_id, "version" => 1},
             "environment_id" => environment_id,
             "vault_ids" => [vault_id],
             "title" => "Existing Session",
             "status" => "idle",
             "archived_at" => nil
           } = json_response(show_conn, 200)

    assert session_id == session.id
    assert agent_id == agent.id
    assert environment_id == environment.id
    assert vault_id == vault.id

    other = Helpers.create_user!()
    other_api_key = Helpers.create_api_key!(other)

    blocked_conn =
      build_conn()
      |> Helpers.authorized_conn(other_api_key)
      |> get(~p"/v1/sessions/#{session.id}")

    assert json_response(blocked_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  test "POST /v1/sessions/:id/events appends multiple events and GET /v1/sessions/:id/events paginates chronologically",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "event-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    append_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "events" => [
          %{
            "type" => "user.message",
            "content" => [%{"type" => "text", "text" => "hello"}]
          },
          %{
            "type" => "user.interrupt",
            "payload" => %{"reason" => "operator-request"}
          },
          %{
            "type" => "user.tool_confirmation",
            "payload" => %{"tool_use_id" => "tool-123", "result" => "allow"}
          }
        ]
      })

    assert %{
             "data" => [
               %{"sequence" => 1, "type" => "user.message"},
               %{"sequence" => 2, "type" => "user.interrupt"},
               %{"sequence" => 3, "type" => "user.tool_confirmation"}
             ],
             "has_more" => false
           } = json_response(append_conn, 201)

    first_page_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session.id}/events", %{"limit" => 2})

    assert %{
             "data" => [
               %{"sequence" => 0, "type" => "session.status_idle"},
               %{"sequence" => 1, "type" => "user.message"}
             ],
             "has_more" => true
           } = json_response(first_page_conn, 200)

    second_page_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session.id}/events", %{"limit" => 2, "after" => 1})

    assert %{
             "data" => [
               %{"sequence" => 2, "type" => "user.interrupt"},
               %{"sequence" => 3, "type" => "user.tool_confirmation"}
             ],
             "has_more" => false
           } = json_response(second_page_conn, 200)
  end

  test "GET /v1/sessions/:id/threads lists persisted threads and thread event endpoints stay scoped",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "thread-root-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)
    primary_thread = primary_thread_for!(owner, session)

    delegate_agent = Helpers.create_agent!(owner, %{name: "thread-delegate-agent"})
    delegate_version = Helpers.latest_agent_version!(owner, delegate_agent)

    delegate_thread =
      create_session_thread!(owner, session, delegate_agent.id, delegate_version.id, %{
        parent_thread_id: primary_thread.id
      })

    create_scoped_session_event!(
      owner,
      session,
      delegate_thread.id,
      "agent.message",
      [%{"type" => "text", "text" => "delegate trace"}],
      %{"phase" => "turn_complete"},
      "thread"
    )

    threads_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session.id}/threads")

    assert %{
             "data" => [
               %{
                 "id" => primary_thread_id,
                 "type" => "session_thread",
                 "role" => "primary",
                 "status" => "idle",
                 "agent" => %{"id" => primary_agent_id, "version" => 1}
               },
               %{
                 "id" => delegate_thread_id,
                 "type" => "session_thread",
                 "parent_thread_id" => parent_thread_id,
                 "role" => "delegate",
                 "status" => "idle",
                 "agent" => %{"id" => delegate_agent_id, "version" => 1}
               }
             ],
             "has_more" => false
           } = json_response(threads_conn, 200)

    assert primary_thread_id == primary_thread.id
    assert primary_agent_id == agent.id
    assert delegate_thread_id == delegate_thread.id
    assert parent_thread_id == primary_thread.id
    assert delegate_agent_id == delegate_agent.id

    thread_events_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session.id}/threads/#{delegate_thread.id}/events")

    assert %{
             "data" => [
               %{
                 "type" => "agent.message",
                 "session_thread_id" => ^delegate_thread_id,
                 "content" => [%{"type" => "text", "text" => "delegate trace"}]
               }
             ],
             "has_more" => false
           } = json_response(thread_events_conn, 200)

    thread_stream_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{session.id}/threads/#{delegate_thread.id}/stream")

    assert thread_stream_conn.status == 200

    assert Enum.map(stream_events(thread_stream_conn), &{&1["session_thread_id"], &1["type"]}) ==
             [
               {delegate_thread.id, "agent.message"}
             ]
  end

  test "POST /v1/sessions/:id/events rejects invalid user event types", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "invalid-event-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "agent.message",
        "content" => [%{"type" => "text", "text" => "not allowed"}]
      })

    assert %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => message
             }
           } = json_response(conn, 400)

    assert message =~ "type must be one of:"
    assert message =~ "user.message"
  end

  test "POST /v1/sessions/:id/events accepts tool confirmation shorthand fields", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "tool-confirmation-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "user.tool_confirmation",
        "tool_use_id" => Ecto.UUID.generate(),
        "result" => "allow"
      })

    assert %{
             "data" => [
               %{
                 "type" => "user.tool_confirmation",
                 "payload" => %{"tool_use_id" => tool_use_id, "result" => "allow"}
               }
             ]
           } = json_response(conn, 201)

    assert is_binary(tool_use_id)
  end

  test "POST /v1/sessions/:id/events accepts custom tool result shorthand fields", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "custom-tool-result-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "user.custom_tool_result",
        "custom_tool_use_id" => Ecto.UUID.generate(),
        "content" => [%{"type" => "text", "text" => "approved"}]
      })

    assert %{
             "data" => [
               %{
                 "type" => "user.custom_tool_result",
                 "payload" => %{"custom_tool_use_id" => custom_tool_use_id},
                 "content" => [%{"type" => "text", "text" => "approved"}]
               }
             ]
           } = json_response(conn, 201)

    assert is_binary(custom_tool_use_id)
  end

  test "POST /v1/sessions/:id/events rejects invalid tool confirmation payloads", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "invalid-tool-confirmation-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "user.tool_confirmation",
        "tool_use_id" => "",
        "result" => "maybe"
      })

    assert %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "tool_use_id is required."
             }
           } = json_response(conn, 400)
  end

  test "POST /v1/sessions/:id/events rejects invalid custom tool result payloads", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "invalid-custom-tool-result-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "user.custom_tool_result",
        "custom_tool_use_id" => ""
      })

    assert %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "custom_tool_use_id is required."
             }
           } = json_response(conn, 400)
  end

  test "GET /v1/sessions/:id/stream replays persisted events as SSE data lines and closes for archived sessions",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "stream-replay-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    {:ok, [_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "replay this"}],
            payload: %{"source" => "test"}
          }
        ],
        owner
      )

    session
    |> Ash.Changeset.for_update(:archive, %{}, actor: owner, domain: Sessions)
    |> Ash.update!()

    stream_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{session.id}/stream")

    assert stream_conn.status == 200
    assert ["text/event-stream; charset=utf-8"] = get_resp_header(stream_conn, "content-type")

    assert Enum.map(stream_events(stream_conn), &{&1["sequence"], &1["type"]}) == [
             {0, "session.status_idle"},
             {1, "user.message"}
           ]
  end

  test "GET /v1/sessions/:id/stream replays persisted events and continues with live broadcasts",
       _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "stream-live-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    stream_request_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("accept", "text/event-stream")

    stream_task =
      Task.async(fn ->
        get(stream_request_conn, ~p"/v1/sessions/#{session.id}/stream", %{"after" => 0})
      end)

    wait_for_stream_subscriber(session.id)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "deliver live"}],
            payload: %{}
          }
        ],
        owner
      )

    current_session = Helpers.get_session!(owner, session.id)

    running_session =
      current_session
      |> Ash.Changeset.for_update(:update, %{status: :running}, actor: owner, domain: Sessions)
      |> Ash.update!()

    idle_session =
      running_session
      |> Ash.Changeset.for_update(:update, %{status: :idle}, actor: owner, domain: Sessions)
      |> Ash.update!()

    idle_session
    |> Ash.Changeset.for_update(:archive, %{}, actor: owner, domain: Sessions)
    |> Ash.update!()

    stream_conn = Task.await(stream_task, 2_000)

    assert stream_conn.status == 200

    assert Enum.map(stream_events(stream_conn), &{&1["sequence"], &1["type"]}) == [
             {1, "user.message"},
             {2, "session.status_running"},
             {3, "session.status_idle"}
           ]
  end

  test "GET /v1/sessions/:id/stream keeps the aggregate view and excludes thread-only delegate traces",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "aggregate-stream-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)
    primary_thread = primary_thread_for!(owner, session)

    delegate_agent = Helpers.create_agent!(owner, %{name: "aggregate-delegate-agent"})
    delegate_version = Helpers.latest_agent_version!(owner, delegate_agent)

    delegate_thread =
      create_session_thread!(owner, session, delegate_agent.id, delegate_version.id, %{
        parent_thread_id: primary_thread.id
      })

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "coordinate"}],
            payload: %{}
          }
        ],
        owner
      )

    create_scoped_session_event!(
      owner,
      session,
      primary_thread.id,
      "session.thread_created",
      [],
      %{"session_thread_id" => delegate_thread.id, "model" => %{"id" => "claude-sonnet-4-6"}},
      "both"
    )

    create_scoped_session_event!(
      owner,
      session,
      delegate_thread.id,
      "agent.message",
      [%{"type" => "text", "text" => "delegate detail"}],
      %{"phase" => "turn_complete"},
      "thread"
    )

    stream_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{session.id}/stream")

    assert stream_conn.status == 200

    assert Enum.map(stream_events(stream_conn), &{&1["sequence"], &1["type"]}) == [
             {0, "session.status_idle"},
             {1, "user.message"},
             {2, "session.thread_created"}
           ]
  end

  test "session event endpoints enforce user scoping", %{conn: conn} do
    owner = Helpers.create_user!()
    agent = Helpers.create_agent!(owner, %{name: "scoped-event-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    other = Helpers.create_user!()
    other_api_key = Helpers.create_api_key!(other)

    get_conn =
      conn
      |> Helpers.authorized_conn(other_api_key)
      |> get(~p"/v1/sessions/#{session.id}/events")

    assert json_response(get_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }

    post_conn =
      build_conn()
      |> Helpers.authorized_conn(other_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session.id}/events", %{
        "type" => "user.message",
        "content" => [%{"type" => "text", "text" => "blocked"}]
      })

    assert json_response(post_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  test "POST /v1/sessions/:id/archive is idempotent and DELETE /v1/sessions/:id preserves history while hiding the row",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "archive-agent"})
    environment = Helpers.create_environment!(owner)
    vault = Helpers.create_vault!(owner)

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => agent.id,
        "environment_id" => environment.id,
        "vault_ids" => [vault.id]
      })

    assert %{"id" => session_id} = json_response(create_conn, 201)

    session = Helpers.get_session!(owner, session_id)
    agent_version = Helpers.latest_agent_version!(owner, agent)
    thread = create_session_thread!(owner, session, agent.id, agent_version.id)
    event = create_session_event!(owner, session, thread.id)

    archive_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> post(~p"/v1/sessions/#{session_id}/archive")

    assert %{
             "id" => archived_session_id,
             "status" => "archived",
             "archived_at" => archived_at
           } = json_response(archive_conn, 200)

    assert archived_session_id == session_id
    assert is_binary(archived_at)

    second_archive_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> post(~p"/v1/sessions/#{session_id}/archive")

    assert %{
             "id" => ^session_id,
             "status" => "archived"
           } = json_response(second_archive_conn, 200)

    delete_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/sessions/#{session_id}")

    assert response(delete_conn, 204)
    assert Helpers.get_session!(owner, session_id) == nil

    deleted_session =
      Helpers.get_session_with_deleted!(owner, session_id, [:session_vaults, :threads, :events])

    assert deleted_session.status == :deleted
    assert %DateTime{} = deleted_session.deleted_at
    assert Enum.map(deleted_session.session_vaults, & &1.vault_id) == [vault.id]
    assert Enum.any?(deleted_session.threads, &(&1.role == :primary))
    assert Enum.any?(deleted_session.threads, &(&1.id == thread.id))
    assert Enum.map(deleted_session.events, & &1.type) == ["session.status_idle", "user.message"]
    assert Enum.any?(deleted_session.events, &(&1.id == event.id))

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/sessions/#{session_id}")

    assert json_response(show_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  defp create_session_vault!(owner, session_id, vault_id, position) do
    JidoManagedAgents.Sessions.SessionVault
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        session_id: session_id,
        vault_id: vault_id,
        position: position,
        metadata: %{}
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp primary_thread_for!(owner, session) do
    {:ok, thread} = SessionThreads.ensure_primary_thread(session, owner, [:agent_version])
    thread
  end

  defp create_session_thread!(owner, session, agent_id, agent_version_id, attrs \\ %{}) do
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
        metadata: %{scope: "v1-controller-test"}
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp create_scoped_session_event!(
         owner,
         session,
         thread_id,
         type,
         content,
         payload,
         stream_scope
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
        metadata: %{"stream_scope" => stream_scope}
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp next_event_sequence!(owner, session) do
    session
    |> then(&Helpers.get_session!(owner, &1.id, [:events]))
    |> Map.fetch!(:events)
    |> List.last()
    |> case do
      nil -> 0
      event -> event.sequence + 1
    end
  end

  defp create_session_event!(owner, session, thread_id) do
    {:ok, [event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            session_thread_id: thread_id,
            type: "user.message",
            content: [%{"type" => "text", "text" => "hello"}],
            payload: %{}
          }
        ],
        owner
      )

    event
  end

  defp build_skill_links(owner, prefix, count) do
    0..(count - 1)
    |> Enum.map(fn index ->
      skill =
        Helpers.create_skill!(owner, %{
          name: "#{prefix}-#{index}-#{System.unique_integer([:positive])}"
        })

      version = Helpers.latest_skill_version!(owner, skill)

      %{
        user_id: owner.id,
        skill_id: skill.id,
        skill_version_id: version.id,
        position: index,
        metadata: %{}
      }
    end)
  end

  defp callable_agent_link(owner, callable_agent, position, version) do
    %{
      user_id: owner.id,
      callable_agent_id: callable_agent.id,
      callable_agent_version_id:
        resolve_callable_agent_version_id(owner, callable_agent, version),
      position: position,
      metadata: %{}
    }
  end

  defp resolve_callable_agent_version_id(_owner, _callable_agent, nil), do: nil

  defp resolve_callable_agent_version_id(owner, callable_agent, version_number) do
    query =
      AgentVersion
      |> Ash.Query.for_read(:read, %{}, actor: owner, domain: JidoManagedAgents.Agents)
      |> Ash.Query.filter(agent_id == ^callable_agent.id and version == ^version_number)

    Ash.read_one!(query).id
  end

  defp stream_events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end

  defp wait_for_stream_subscriber(session_id, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_stream_subscriber(session_id, deadline)
  end

  defp do_wait_for_stream_subscriber(session_id, deadline) do
    if Registry.lookup(JidoManagedAgents.PubSub, stream_topic(session_id)) == [] do
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_for_stream_subscriber(session_id, deadline)
      else
        raise ExUnit.AssertionError,
          message: "expected an SSE stream subscriber for session #{session_id}"
      end
    else
      :ok
    end
  end

  defp stream_topic(session_id), do: "sessions:#{session_id}:stream"
end
