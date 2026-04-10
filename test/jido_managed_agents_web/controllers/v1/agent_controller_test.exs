defmodule JidoManagedAgentsWeb.V1.AgentControllerTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  test "GET /v1/agents rejects requests without x-api-key", %{conn: conn} do
    conn =
      conn
      |> Helpers.json_conn()
      |> get(~p"/v1/agents")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "POST /v1/agents creates an initial version with Anthropic-compatible fields", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    custom_skill = Helpers.create_skill!(owner, %{name: "research-brief"})

    Helpers.create_skill_version!(owner, custom_skill, %{
      version: 2,
      body: "Escalate missing facts."
    })

    anthropic_skill = Helpers.create_skill!(owner, %{type: :anthropic, name: "anthropic-search"})
    callable_agent = Helpers.create_agent!(owner, %{name: "delegate-agent"})

    payload = %{
      "name" => "Coding Assistant",
      "model" => "claude-sonnet-4-6",
      "system" => "You are a helpful coding agent.",
      "tools" => [
        %{
          "type" => "agent_toolset_20260401",
          "configs" => %{
            "write" => %{"permission_policy" => "always_allow"},
            "web_search" => %{"enabled" => false}
          }
        },
        %{"type" => "mcp_toolset", "mcp_server_name" => "docs"},
        %{
          "type" => "custom",
          "name" => "lookup_release",
          "description" => "Looks up release notes.",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"package" => %{"type" => "string"}}
          }
        }
      ],
      "mcp_servers" => [%{"type" => "url", "name" => "docs", "url" => "https://example.com/mcp"}],
      "skills" => [
        %{"type" => "custom", "skill_id" => custom_skill.id, "version" => 2},
        %{"type" => "anthropic", "skill_id" => anthropic_skill.id, "version" => 1}
      ],
      "callable_agents" => [%{"id" => callable_agent.id, "version" => 1}],
      "description" => "Writes production code.",
      "metadata" => %{"team" => "platform"}
    }

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/agents", payload)

    assert %{
             "id" => agent_id,
             "type" => "agent",
             "name" => "Coding Assistant",
             "model" => %{"id" => "claude-sonnet-4-6", "speed" => "standard"},
             "system" => "You are a helpful coding agent.",
             "tools" => [
               %{
                 "type" => "agent_toolset_20260401",
                 "default_config" => %{"permission_policy" => "always_ask"},
                 "configs" => %{
                   "write" => %{"permission_policy" => "always_allow"},
                   "web_search" => %{"enabled" => false}
                 }
               },
               %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "docs",
                 "permission_policy" => "always_ask"
               },
               %{
                 "type" => "custom",
                 "name" => "lookup_release",
                 "description" => "Looks up release notes.",
                 "input_schema" => %{
                   "type" => "object",
                   "properties" => %{"package" => %{"type" => "string"}}
                 },
                 "permission_policy" => "always_ask"
               }
             ],
             "mcp_servers" => [
               %{"type" => "url", "name" => "docs", "url" => "https://example.com/mcp"}
             ],
             "skills" => [
               %{"type" => "custom", "skill_id" => custom_skill_id, "version" => 2},
               %{"type" => "anthropic", "skill_id" => anthropic_skill_id, "version" => 1}
             ],
             "callable_agents" => [
               %{"type" => "agent", "id" => callable_agent_id, "version" => 1}
             ],
             "description" => "Writes production code.",
             "metadata" => %{"team" => "platform"},
             "version" => 1,
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 201)

    assert agent_id
    assert custom_skill_id == custom_skill.id
    assert anthropic_skill_id == anthropic_skill.id
    assert callable_agent_id == callable_agent.id
    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "POST /v1/agents rejects invalid tool declarations", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/agents", %{
        "name" => "Invalid Tool Agent",
        "model" => "claude-sonnet-4-6",
        "tools" => [
          %{
            "type" => "agent_toolset_20260401",
            "configs" => %{"deploy" => %{"enabled" => false}}
          }
        ]
      })

    assert json_response(conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "tools.0.configs.deploy is not a supported built-in tool."
             }
           }
  end

  test "POST /v1/agents rejects invalid skill references", _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    custom_skill = Helpers.create_skill!(owner, %{name: "typed-skill"})
    missing_skill_id = Ecto.UUID.generate()

    cases = [
      {[%{"skill_id" => custom_skill.id}], "skills[0].type is required."},
      {[%{"type" => "anthropic", "skill_id" => custom_skill.id}],
       "skills[0].type must match the referenced skill's persisted type."},
      {[%{"type" => "custom", "skill_id" => missing_skill_id}],
       "skill #{missing_skill_id} was not found."},
      {[%{"type" => "custom", "skill_id" => custom_skill.id, "version" => 99}],
       "skills[0].version references an unknown skill version."}
    ]

    Enum.each(cases, fn {skills, expected_message} ->
      conn =
        build_conn()
        |> Helpers.authorized_conn(owner_api_key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/agents", %{
          "name" => "invalid-skill-agent-#{System.unique_integer([:positive])}",
          "model" => "claude-sonnet-4-6",
          "skills" => skills
        })

      assert json_response(conn, 400) == %{
               "error" => %{
                 "type" => "invalid_request_error",
                 "message" => expected_message
               }
             }
    end)
  end

  test "POST /v1/agents accepts all supported model shapes", _context do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    cases = [
      {%{"id" => "claude-opus-4-6", "speed" => "fast"},
       %{"id" => "claude-opus-4-6", "speed" => "fast"}},
      {"openai:gpt-4o", %{"provider" => "openai", "id" => "gpt-4o"}},
      {%{"provider" => "openai", "id" => "gpt-4o-mini"},
       %{"provider" => "openai", "id" => "gpt-4o-mini"}}
    ]

    Enum.each(cases, fn {model, expected_model} ->
      conn =
        build_conn()
        |> Helpers.authorized_conn(owner_api_key)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/agents", %{
          "name" => "agent-#{System.unique_integer([:positive])}",
          "model" => model
        })

      assert %{
               "type" => "agent",
               "model" => ^expected_model,
               "version" => 1
             } = json_response(conn, 201)
    end)
  end

  test "GET /v1/agents returns newest first, excludes archived agents, and isolates users", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    oldest = Helpers.create_agent!(owner, %{name: "oldest-agent"})
    Process.sleep(1)
    archived = Helpers.create_agent!(owner, %{name: "archived-agent"})
    Process.sleep(1)
    newest = Helpers.create_agent!(owner, %{name: "newest-agent"})
    Helpers.archive_agent!(owner, archived)

    other = Helpers.create_user!()
    Helpers.create_agent!(other, %{name: "other-agent"})

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("anthropic-version", "2023-06-01")
      |> put_req_header("anthropic-beta", "managed-agents-local-2026-04-09")
      |> get(~p"/v1/agents")

    assert %{
             "data" => [
               %{"id" => newest_id, "type" => "agent", "version" => 1},
               %{"id" => oldest_id, "type" => "agent", "version" => 1}
             ],
             "has_more" => false
           } = json_response(conn, 200)

    assert newest_id == newest.id
    assert oldest_id == oldest.id
    refute newest_id == archived.id
    refute oldest_id == archived.id
  end

  test "GET /v1/agents/:id returns the latest version shape", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    agent =
      Helpers.create_agent!(owner, %{
        name: "owner-agent",
        description: "Agent for retrieval tests",
        model: %{"id" => "claude-opus-4-6", "speed" => "fast"},
        system: "Stay precise.",
        tools: [%{"type" => "agent_toolset_20260401"}],
        mcp_servers: [%{"type" => "url", "name" => "notes", "url" => "https://example.com"}],
        metadata: %{"scope" => "show-test"}
      })

    agent_id = agent.id

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/agents/#{agent_id}")

    expected_tools = [builtin_toolset()]

    assert %{
             "id" => ^agent_id,
             "type" => "agent",
             "name" => "owner-agent",
             "model" => %{"id" => "claude-opus-4-6", "speed" => "fast"},
             "system" => "Stay precise.",
             "tools" => ^expected_tools,
             "mcp_servers" => [
               %{"type" => "url", "name" => "notes", "url" => "https://example.com"}
             ],
             "skills" => [],
             "callable_agents" => [],
             "description" => "Agent for retrieval tests",
             "metadata" => %{"scope" => "show-test"},
             "version" => 1,
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 200)

    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "PUT /v1/agents/:id creates a new immutable version with merge semantics", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    original_skill = Helpers.create_skill!(owner, %{name: "original-skill"})
    replacement_skill = Helpers.create_skill!(owner, %{name: "replacement-skill"})
    original_callable = Helpers.create_agent!(owner, %{name: "original-callable"})
    replacement_callable = Helpers.create_agent!(owner, %{name: "replacement-callable"})

    create_payload = %{
      "name" => "Versioned Agent",
      "model" => %{"id" => "claude-opus-4-6", "speed" => "fast"},
      "system" => "Stay on task.",
      "tools" => [%{"type" => "agent_toolset_20260401"}],
      "mcp_servers" => [%{"type" => "url", "name" => "docs", "url" => "https://example.com"}],
      "skills" => [%{"type" => "custom", "skill_id" => original_skill.id, "version" => 1}],
      "callable_agents" => [%{"id" => original_callable.id, "version" => 1}],
      "description" => "Original description",
      "metadata" => %{"team" => "platform", "deprecated" => "true"}
    }

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/agents", create_payload)

    %{"id" => agent_id} = json_response(create_conn, 201)

    update_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/agents/#{agent_id}", %{
        "version" => 1,
        "tools" => [],
        "skills" => [%{"type" => "custom", "skill_id" => replacement_skill.id, "version" => 1}],
        "callable_agents" => [%{"id" => replacement_callable.id}],
        "description" => "Updated description",
        "metadata" => %{"team" => "runtime", "deprecated" => "", "tier" => "gold"}
      })

    assert %{
             "id" => ^agent_id,
             "name" => "Versioned Agent",
             "model" => %{"id" => "claude-opus-4-6", "speed" => "fast"},
             "system" => "Stay on task.",
             "tools" => [],
             "mcp_servers" => [
               %{"type" => "url", "name" => "docs", "url" => "https://example.com"}
             ],
             "skills" => [
               %{"type" => "custom", "skill_id" => replacement_skill_id, "version" => 1}
             ],
             "callable_agents" => [
               %{"type" => "agent", "id" => replacement_callable_id}
             ],
             "description" => "Updated description",
             "metadata" => %{"team" => "runtime", "tier" => "gold"},
             "version" => 2,
             "archived_at" => nil
           } = json_response(update_conn, 200)

    assert replacement_skill_id == replacement_skill.id
    assert replacement_callable_id == replacement_callable.id

    versions_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/agents/#{agent_id}/versions")

    assert %{
             "data" => [
               %{
                 "id" => ^agent_id,
                 "version" => 2,
                 "description" => "Updated description",
                 "metadata" => %{"team" => "runtime", "tier" => "gold"}
               },
               %{
                 "id" => ^agent_id,
                 "version" => 1,
                 "description" => "Original description",
                 "metadata" => %{"team" => "platform", "deprecated" => "true"}
               }
             ],
             "has_more" => false
           } = json_response(versions_conn, 200)
  end

  test "PUT /v1/agents/:id detects no-op updates and keeps the current version", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    create_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/agents", %{
        "name" => "Noop Agent",
        "model" => "claude-sonnet-4-6",
        "metadata" => %{"team" => "platform"}
      })

    %{"id" => agent_id} = json_response(create_conn, 201)

    update_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/agents/#{agent_id}", %{"version" => 1})

    assert %{
             "id" => ^agent_id,
             "version" => 1,
             "metadata" => %{"team" => "platform"}
           } = json_response(update_conn, 200)

    versions_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/agents/#{agent_id}/versions")

    assert %{"data" => [%{"version" => 1}], "has_more" => false} =
             json_response(versions_conn, 200)
  end

  test "POST /v1/agents/:id/archive marks the agent archived and future updates are rejected", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "archive-me"})

    archive_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> post(~p"/v1/agents/#{agent.id}/archive")

    assert %{
             "id" => agent_id,
             "version" => 1,
             "archived_at" => archived_at
           } = json_response(archive_conn, 200)

    assert agent_id == agent.id
    assert is_binary(archived_at)

    update_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> put(~p"/v1/agents/#{agent.id}", %{
        "version" => 1,
        "description" => "should fail"
      })

    assert json_response(update_conn, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "Archived agents are read-only."
             }
           }
  end

  test "DELETE /v1/agents/:id rejects agents with dependent sessions", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "session-bound-agent"})
    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    delete_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/agents/#{agent.id}")

    assert json_response(delete_conn, 409) == %{
             "error" => %{
               "type" => "conflict_error",
               "message" => "Cannot delete an agent that has dependent sessions."
             }
           }
  end

  test "DELETE /v1/agents/:id deletes agents that have no dependent sessions", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)
    agent = Helpers.create_agent!(owner, %{name: "deletable-agent"})

    delete_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> delete(~p"/v1/agents/#{agent.id}")

    assert response(delete_conn, 204) == ""

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/agents/#{agent.id}")

    assert json_response(show_conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  test "GET /v1/agents/:id blocks cross-user access", %{conn: conn} do
    owner = Helpers.create_user!()
    owner_agent = Helpers.create_agent!(owner)

    other = Helpers.create_user!()
    other_api_key = Helpers.create_api_key!(other)

    conn =
      conn
      |> Helpers.authorized_conn(other_api_key)
      |> get(~p"/v1/agents/#{owner_agent.id}")

    assert json_response(conn, 404) == %{
             "error" => %{
               "type" => "not_found_error",
               "message" => "Resource not found."
             }
           }
  end

  defp builtin_toolset(attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "agent_toolset_20260401",
        "default_config" => %{"permission_policy" => "always_ask"},
        "configs" => %{}
      },
      attrs
    )
  end
end
