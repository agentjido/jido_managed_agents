defmodule JidoManagedAgentsWeb.V1OpenApiSpec do
  @moduledoc false
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Operation,
    PathItem,
    Reference,
    Schema,
    SecurityScheme,
    Server,
    Tag
  }

  @json "application/json"
  @sse "text/event-stream"

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Jido Managed Agents /v1 API",
        version: app_version(),
        description:
          "Anthropic-style managed agent API for agents, skills, environments, vaults, credentials, and sessions."
      },
      servers: [Server.from_endpoint(JidoManagedAgentsWeb.Endpoint)],
      tags: tags(),
      security: [%{"apiKey" => []}],
      components: %Components{
        schemas: schemas(),
        securitySchemes: %{
          "apiKey" => %SecurityScheme{
            type: "apiKey",
            name: "x-api-key",
            in: "header",
            description:
              "Generate a key from the console API docs screen and send it on every `/v1` request."
          }
        }
      },
      paths: paths()
    }
  end

  defp app_version do
    case Application.spec(:jido_managed_agents, :vsn) do
      nil -> "0.1.0"
      version -> List.to_string(version)
    end
  end

  defp tags do
    [
      %Tag{name: "Agents", description: "Managed agent definitions and versions."},
      %Tag{name: "Skills", description: "Reusable skill definitions and versions."},
      %Tag{name: "Environments", description: "Reusable runtime environment templates."},
      %Tag{name: "Vaults", description: "Secret vaults and stored credentials."},
      %Tag{name: "Sessions", description: "Session lifecycle, events, and streams."}
    ]
  end

  defp paths do
    %{
      "/v1/agents" => %PathItem{
        get:
          operation("Agents", "listAgents", "List agents",
            description: "Returns active agents ordered by most recent first.",
            responses: json_responses(200, "Agent collection.", "AgentList", [401, 403, 500])
          ),
        post:
          operation("Agents", "createAgent", "Create an agent",
            description: "Creates a managed agent and its initial version.",
            request_body: json_request("Agent definition body.", "CreateAgentRequest"),
            responses: json_responses(201, "Agent created.", "Agent", [400, 401, 403, 500])
          )
      },
      "/v1/agents/{id}" => %PathItem{
        get:
          operation("Agents", "getAgent", "Fetch an agent",
            description: "Returns the latest version of an agent.",
            parameters: [id_param("agent")],
            responses: json_responses(200, "Agent detail.", "Agent", [401, 403, 404, 500])
          ),
        put:
          operation("Agents", "updateAgent", "Update an agent",
            description: "Updates an agent and produces a new latest version.",
            parameters: [id_param("agent")],
            request_body: json_request("Partial agent definition body.", "UpdateAgentRequest"),
            responses: json_responses(200, "Agent updated.", "Agent", [400, 401, 403, 404, 500])
          ),
        delete:
          operation("Agents", "deleteAgent", "Delete an agent",
            description: "Deletes an agent and all stored versions.",
            parameters: [id_param("agent")],
            responses: no_content_responses([401, 403, 404, 500])
          )
      },
      "/v1/agents/{id}/versions" => %PathItem{
        get:
          operation("Agents", "listAgentVersions", "List agent versions",
            description: "Returns all stored versions for an agent.",
            parameters: [id_param("agent")],
            responses:
              json_responses(200, "Agent versions.", "AgentVersionList", [401, 403, 404, 500])
          )
      },
      "/v1/agents/{id}/archive" => %PathItem{
        post:
          operation("Agents", "archiveAgent", "Archive an agent",
            description: "Marks an agent as archived.",
            parameters: [id_param("agent")],
            responses: json_responses(200, "Agent archived.", "Agent", [401, 403, 404, 500])
          )
      },
      "/v1/skills" => %PathItem{
        get:
          operation("Skills", "listSkills", "List skills",
            description: "Returns active skills ordered by most recent first.",
            responses: json_responses(200, "Skill collection.", "SkillList", [401, 403, 500])
          ),
        post:
          operation("Skills", "createSkill", "Create a skill",
            description: "Creates a skill and its initial version.",
            request_body: json_request("Skill definition body.", "CreateSkillRequest"),
            responses: json_responses(201, "Skill created.", "Skill", [400, 401, 403, 500])
          )
      },
      "/v1/skills/{id}" => %PathItem{
        get:
          operation("Skills", "getSkill", "Fetch a skill",
            description: "Returns the latest version of a skill, including the body.",
            parameters: [id_param("skill")],
            responses: json_responses(200, "Skill detail.", "Skill", [401, 403, 404, 500])
          )
      },
      "/v1/skills/{id}/versions" => %PathItem{
        get:
          operation("Skills", "listSkillVersions", "List skill versions",
            description: "Returns all stored versions for a skill.",
            parameters: [id_param("skill")],
            responses:
              json_responses(200, "Skill versions.", "SkillVersionList", [401, 403, 404, 500])
          )
      },
      "/v1/environments" => %PathItem{
        get:
          operation("Environments", "listEnvironments", "List environments",
            description: "Returns active runtime environment templates.",
            responses:
              json_responses(200, "Environment collection.", "EnvironmentList", [401, 403, 500])
          ),
        post:
          operation("Environments", "createEnvironment", "Create an environment",
            description: "Creates a runtime environment template.",
            request_body:
              json_request("Environment definition body.", "CreateEnvironmentRequest"),
            responses:
              json_responses(201, "Environment created.", "Environment", [400, 401, 403, 500])
          )
      },
      "/v1/environments/{id}" => %PathItem{
        get:
          operation("Environments", "getEnvironment", "Fetch an environment",
            description: "Returns a runtime environment template.",
            parameters: [id_param("environment")],
            responses:
              json_responses(200, "Environment detail.", "Environment", [401, 403, 404, 500])
          ),
        put:
          operation("Environments", "updateEnvironment", "Update an environment",
            description: "Updates a runtime environment template.",
            parameters: [id_param("environment")],
            request_body:
              json_request("Partial environment definition body.", "UpdateEnvironmentRequest"),
            responses:
              json_responses(200, "Environment updated.", "Environment", [
                400,
                401,
                403,
                404,
                500
              ])
          ),
        delete:
          operation("Environments", "deleteEnvironment", "Delete an environment",
            description: "Deletes an environment when it has no active blockers.",
            parameters: [id_param("environment")],
            responses: no_content_responses([401, 403, 404, 409, 500])
          )
      },
      "/v1/environments/{id}/archive" => %PathItem{
        post:
          operation("Environments", "archiveEnvironment", "Archive an environment",
            description: "Marks an environment as archived.",
            parameters: [id_param("environment")],
            responses:
              json_responses(200, "Environment archived.", "Environment", [
                401,
                403,
                404,
                500
              ])
          )
      },
      "/v1/vaults" => %PathItem{
        get:
          operation("Vaults", "listVaults", "List vaults",
            description: "Returns vaults ordered by most recent first.",
            responses: json_responses(200, "Vault collection.", "VaultList", [401, 403, 500])
          ),
        post:
          operation("Vaults", "createVault", "Create a vault",
            description: "Creates a secret vault.",
            request_body: json_request("Vault definition body.", "CreateVaultRequest"),
            responses: json_responses(201, "Vault created.", "Vault", [400, 401, 403, 500])
          )
      },
      "/v1/vaults/{id}" => %PathItem{
        get:
          operation("Vaults", "getVault", "Fetch a vault",
            description: "Returns a vault.",
            parameters: [id_param("vault")],
            responses: json_responses(200, "Vault detail.", "Vault", [401, 403, 404, 500])
          ),
        delete:
          operation("Vaults", "deleteVault", "Delete a vault",
            description: "Deletes a vault and any credentials stored inside it.",
            parameters: [id_param("vault")],
            responses: no_content_responses([401, 403, 404, 500])
          )
      },
      "/v1/vaults/{vault_id}/credentials" => %PathItem{
        get:
          operation("Vaults", "listVaultCredentials", "List vault credentials",
            description: "Returns credentials stored in a vault.",
            parameters: [vault_id_param()],
            responses:
              json_responses(200, "Credential collection.", "CredentialList", [
                401,
                403,
                404,
                500
              ])
          ),
        post:
          operation("Vaults", "createVaultCredential", "Create a vault credential",
            description: "Creates a credential inside a vault.",
            parameters: [vault_id_param()],
            request_body: json_request("Credential definition body.", "CreateCredentialRequest"),
            responses:
              json_responses(201, "Credential created.", "Credential", [
                400,
                401,
                403,
                404,
                500
              ])
          )
      },
      "/v1/vaults/{vault_id}/credentials/{id}" => %PathItem{
        get:
          operation("Vaults", "getVaultCredential", "Fetch a vault credential",
            description: "Returns a credential stored in a vault.",
            parameters: [vault_id_param(), id_param("credential")],
            responses:
              json_responses(200, "Credential detail.", "Credential", [401, 403, 404, 500])
          ),
        put:
          operation("Vaults", "updateVaultCredential", "Update a vault credential",
            description: "Updates mutable credential fields.",
            parameters: [vault_id_param(), id_param("credential")],
            request_body: json_request("Credential update body.", "UpdateCredentialRequest"),
            responses:
              json_responses(200, "Credential updated.", "Credential", [
                400,
                401,
                403,
                404,
                500
              ])
          ),
        delete:
          operation("Vaults", "deleteVaultCredential", "Delete a vault credential",
            description: "Deletes a credential from a vault.",
            parameters: [vault_id_param(), id_param("credential")],
            responses: no_content_responses([401, 403, 404, 500])
          )
      },
      "/v1/sessions" => %PathItem{
        get:
          operation("Sessions", "listSessions", "List sessions",
            description: "Returns sessions ordered by most recent first.",
            responses: json_responses(200, "Session collection.", "SessionList", [401, 403, 500])
          ),
        post:
          operation("Sessions", "createSession", "Create a session",
            description: "Launches a new session for an agent and environment.",
            request_body: json_request("Session launch body.", "CreateSessionRequest"),
            responses:
              json_responses(201, "Session created.", "Session", [400, 401, 403, 409, 500])
          )
      },
      "/v1/sessions/{id}" => %PathItem{
        get:
          operation("Sessions", "getSession", "Fetch a session",
            description: "Returns a session.",
            parameters: [id_param("session")],
            responses: json_responses(200, "Session detail.", "Session", [401, 403, 404, 500])
          ),
        delete:
          operation("Sessions", "deleteSession", "Delete a session",
            description: "Soft deletes a session.",
            parameters: [id_param("session")],
            responses: no_content_responses([401, 403, 404, 500])
          )
      },
      "/v1/sessions/{id}/archive" => %PathItem{
        post:
          operation("Sessions", "archiveSession", "Archive a session",
            description: "Marks a session as archived.",
            parameters: [id_param("session")],
            responses: json_responses(200, "Session archived.", "Session", [401, 403, 404, 500])
          )
      },
      "/v1/sessions/{id}/events" => %PathItem{
        get:
          operation("Sessions", "listSessionEvents", "List session events",
            description: "Returns persisted events for a session.",
            parameters: [id_param("session"), limit_param(), after_param()],
            responses:
              json_responses(200, "Session event collection.", "SessionEventList", [
                400,
                401,
                403,
                404,
                500
              ])
          ),
        post:
          operation("Sessions", "appendSessionEvents", "Append session events",
            description: "Appends one or more user-originated events to a session.",
            parameters: [id_param("session")],
            request_body:
              json_request(
                "Single event object or `{events: [...]}` batch.",
                "AppendSessionEventsRequest"
              ),
            responses:
              json_responses(201, "Session events appended.", "SessionEventList", [
                400,
                401,
                403,
                404,
                500
              ])
          )
      },
      "/v1/sessions/{id}/stream" => %PathItem{
        get:
          operation("Sessions", "streamSessionEvents", "Stream session events",
            description: "Streams visible session events as server-sent events.",
            parameters: [id_param("session"), after_param()],
            responses: event_stream_responses([400, 401, 403, 404, 500])
          )
      },
      "/v1/sessions/{id}/threads" => %PathItem{
        get:
          operation("Sessions", "listSessionThreads", "List session threads",
            description: "Returns threads belonging to a session.",
            parameters: [id_param("session")],
            responses:
              json_responses(200, "Session thread collection.", "SessionThreadList", [
                401,
                403,
                404,
                500
              ])
          )
      },
      "/v1/sessions/{id}/threads/{thread_id}/events" => %PathItem{
        get:
          operation("Sessions", "listSessionThreadEvents", "List thread events",
            description: "Returns persisted events for a session thread.",
            parameters: [id_param("session"), thread_id_param(), limit_param(), after_param()],
            responses:
              json_responses(200, "Session thread event collection.", "SessionEventList", [
                400,
                401,
                403,
                404,
                500
              ])
          )
      },
      "/v1/sessions/{id}/threads/{thread_id}/stream" => %PathItem{
        get:
          operation("Sessions", "streamSessionThreadEvents", "Stream thread events",
            description: "Streams thread events as server-sent events.",
            parameters: [id_param("session"), thread_id_param(), after_param()],
            responses: event_stream_responses([400, 401, 403, 404, 500])
          )
      }
    }
  end

  defp schemas do
    %{
      "ErrorEnvelope" => error_envelope_schema(),
      "StructuredModel" => structured_model_schema(),
      "AgentReference" => agent_reference_schema(),
      "Agent" => agent_schema(),
      "AgentList" => list_envelope_schema("AgentList", ref("Agent"), [agent_example()]),
      "AgentVersionList" =>
        list_envelope_schema("AgentVersionList", ref("Agent"), [agent_version_example()]),
      "CreateAgentRequest" => create_agent_request_schema(),
      "UpdateAgentRequest" => update_agent_request_schema(),
      "Skill" => skill_schema(),
      "SkillList" => list_envelope_schema("SkillList", ref("Skill"), [skill_example()]),
      "SkillVersionList" =>
        list_envelope_schema("SkillVersionList", ref("Skill"), [skill_version_example()]),
      "CreateSkillRequest" => create_skill_request_schema(),
      "Environment" => environment_schema(),
      "EnvironmentList" =>
        list_envelope_schema("EnvironmentList", ref("Environment"), [environment_example()]),
      "CreateEnvironmentRequest" => create_environment_request_schema(),
      "UpdateEnvironmentRequest" => update_environment_request_schema(),
      "Vault" => vault_schema(),
      "VaultList" => list_envelope_schema("VaultList", ref("Vault"), [vault_example()]),
      "CreateVaultRequest" => create_vault_request_schema(),
      "CredentialAuth" => credential_auth_schema(),
      "Credential" => credential_schema(),
      "CredentialList" =>
        list_envelope_schema("CredentialList", ref("Credential"), [credential_example()]),
      "CreateCredentialRequest" => create_credential_request_schema(),
      "UpdateCredentialRequest" => update_credential_request_schema(),
      "Session" => session_schema(),
      "SessionList" => list_envelope_schema("SessionList", ref("Session"), [session_example()]),
      "CreateSessionRequest" => create_session_request_schema(),
      "SessionEvent" => session_event_schema(),
      "SessionEventList" =>
        list_envelope_schema("SessionEventList", ref("SessionEvent"), [session_event_example()]),
      "SessionEventInput" => session_event_input_schema(),
      "AppendSessionEventsRequest" => append_session_events_request_schema(),
      "SessionThread" => session_thread_schema(),
      "SessionThreadList" =>
        list_envelope_schema("SessionThreadList", ref("SessionThread"), [session_thread_example()])
    }
  end

  defp error_envelope_schema do
    %Schema{
      title: "ErrorEnvelope",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            type: %Schema{type: :string, example: "invalid_request_error"},
            message: %Schema{
              type: :string,
              example: "Request body must be a JSON object."
            }
          },
          required: [:type, :message]
        }
      },
      required: [:error],
      example: error_example(400)
    }
  end

  defp structured_model_schema do
    %Schema{
      title: "StructuredModel",
      type: :object,
      properties: %{
        provider: %Schema{type: :string, example: "anthropic"},
        id: %Schema{type: :string, example: "claude-sonnet-4-6"},
        speed: %Schema{type: :string, example: "standard", nullable: true}
      },
      required: [:provider, :id],
      additionalProperties: true,
      example: %{
        "provider" => "anthropic",
        "id" => "claude-sonnet-4-6",
        "speed" => "standard"
      }
    }
  end

  defp agent_reference_schema do
    %Schema{
      title: "AgentReference",
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["agent"], example: "agent"},
        id: %Schema{type: :string, example: "agt_01JABCDEF1234567890"},
        version: %Schema{type: :integer, minimum: 1, example: 1, nullable: true}
      },
      required: [:type, :id],
      example: %{
        "type" => "agent",
        "id" => "agt_01JABCDEF1234567890",
        "version" => 1
      }
    }
  end

  defp agent_schema do
    %Schema{
      title: "Agent",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "agt_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["agent"], example: "agent"},
        name: %Schema{type: :string, example: "Coding Assistant"},
        model: model_schema(),
        system: %Schema{
          type: :string,
          nullable: true,
          example: "You are a senior software engineer."
        },
        tools: object_array_schema(agent_tools_example()),
        mcp_servers: object_array_schema(agent_mcp_servers_example()),
        skills: object_array_schema([]),
        callable_agents: object_array_schema([]),
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Handles day-to-day engineering tasks."
        },
        metadata: object_map_schema(agent_metadata_example()),
        version: %Schema{type: :integer, minimum: 1, example: 1, nullable: true},
        archived_at: datetime_schema(nil, nullable: true),
        created_at: datetime_schema("2026-04-12T16:15:00Z"),
        updated_at: datetime_schema("2026-04-12T16:15:00Z")
      },
      required: [:id, :type, :name],
      additionalProperties: true,
      example: agent_example()
    }
  end

  defp create_agent_request_schema do
    %Schema{
      title: "CreateAgentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, example: "Coding Assistant"},
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Handles day-to-day engineering tasks."
        },
        model: model_schema(),
        system: %Schema{
          type: :string,
          nullable: true,
          example: "You are a senior software engineer."
        },
        tools: object_array_schema(agent_tools_example()),
        mcp_servers: object_array_schema(agent_mcp_servers_example()),
        skills: object_array_schema([]),
        callable_agents: object_array_schema([]),
        metadata: object_map_schema(agent_metadata_example())
      },
      required: [:name, :model],
      additionalProperties: true,
      example: create_agent_request_example()
    }
  end

  defp update_agent_request_schema do
    %Schema{
      title: "UpdateAgentRequest",
      type: :object,
      properties: create_agent_request_schema().properties,
      additionalProperties: true,
      example: %{
        "description" => "Handles escalations and implementation work.",
        "model" => %{"provider" => "openai", "id" => "gpt-5.4"},
        "metadata" => %{"team" => "platform"}
      }
    }
  end

  defp skill_schema do
    %Schema{
      title: "Skill",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "skl_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["skill"], example: "skill"},
        skill_type: %Schema{type: :string, example: "custom"},
        name: %Schema{type: :string, example: "docx"},
        description: %Schema{
          type: :string,
          example: "Summarize doc changes into a concise status update."
        },
        version: %Schema{type: :integer, minimum: 1, example: 1, nullable: true},
        metadata: object_map_schema(%{"team" => "platform"}),
        version_metadata: object_map_schema(%{"owner" => "platform"}),
        allowed_tools: %Schema{
          type: :array,
          items: %Schema{type: :string},
          example: ["read", "web_search"]
        },
        manifest: object_map_schema(%{"name" => "docx", "version" => "0.1.0"}),
        source_path: %Schema{
          type: :string,
          nullable: true,
          example: "/Users/demo/skills/docx/SKILL.md"
        },
        body: %Schema{
          type: :string,
          nullable: true,
          example: "Read the supplied docs and return the salient changes."
        },
        archived_at: datetime_schema(nil, nullable: true),
        created_at: datetime_schema("2026-04-12T16:16:00Z"),
        updated_at: datetime_schema("2026-04-12T16:16:00Z")
      },
      required: [:id, :type, :name, :description],
      additionalProperties: true,
      example: skill_example()
    }
  end

  defp create_skill_request_schema do
    %Schema{
      title: "CreateSkillRequest",
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["anthropic", "custom"], example: "custom"},
        name: %Schema{type: :string, example: "docx"},
        description: %Schema{
          type: :string,
          example: "Summarize doc changes into a concise status update."
        },
        body: %Schema{
          type: :string,
          nullable: true,
          example: "Read the supplied docs and return the salient changes."
        },
        source_path: %Schema{
          type: :string,
          nullable: true,
          example: "/Users/demo/skills/docx/SKILL.md"
        },
        allowed_tools: %Schema{
          type: :array,
          items: %Schema{type: :string},
          example: ["read", "web_search"]
        },
        metadata: object_map_schema(%{"team" => "platform"}),
        version_metadata: object_map_schema(%{"owner" => "platform"}),
        manifest: object_map_schema(%{"name" => "docx", "version" => "0.1.0"})
      },
      required: [:name, :description],
      additionalProperties: true,
      example: create_skill_request_example()
    }
  end

  defp environment_schema do
    %Schema{
      title: "Environment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "env_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["environment"], example: "environment"},
        name: %Schema{type: :string, example: "Restricted Demo Sandbox"},
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Reusable sandbox for API-launched sessions."
        },
        config: object_map_schema(environment_config_example()),
        metadata: object_map_schema(%{"team" => "ops"}),
        archived_at: datetime_schema(nil, nullable: true),
        created_at: datetime_schema("2026-04-12T16:17:00Z"),
        updated_at: datetime_schema("2026-04-12T16:17:00Z")
      },
      required: [:id, :type, :name, :config],
      additionalProperties: true,
      example: environment_example()
    }
  end

  defp create_environment_request_schema do
    %Schema{
      title: "CreateEnvironmentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, example: "Restricted Demo Sandbox"},
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Reusable sandbox for API-launched sessions."
        },
        config: object_map_schema(environment_config_example()),
        metadata: object_map_schema(%{"team" => "ops"})
      },
      required: [:name, :config],
      additionalProperties: true,
      example: create_environment_request_example()
    }
  end

  defp update_environment_request_schema do
    %Schema{
      title: "UpdateEnvironmentRequest",
      type: :object,
      properties: create_environment_request_schema().properties,
      additionalProperties: true,
      example: %{
        "description" => "Sandbox for user-triggered debugging sessions.",
        "config" => %{"type" => "cloud", "networking" => %{"type" => "unrestricted"}}
      }
    }
  end

  defp vault_schema do
    %Schema{
      title: "Vault",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "vlt_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["vault"], example: "vault"},
        name: %Schema{type: :string, example: "production-secrets"},
        display_name: %Schema{type: :string, example: "Production Secrets"},
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Credentials for production MCP servers."
        },
        display_metadata:
          object_map_schema(%{"display_name" => "Production Secrets", "label" => "Primary"}),
        metadata: object_map_schema(%{"external_user_id" => "usr_abc123"}),
        created_at: datetime_schema("2026-04-12T16:18:00Z"),
        updated_at: datetime_schema("2026-04-12T16:18:00Z")
      },
      required: [:id, :type, :name, :display_name],
      additionalProperties: true,
      example: vault_example()
    }
  end

  defp create_vault_request_schema do
    %Schema{
      title: "CreateVaultRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, nullable: true, example: "production-secrets"},
        display_name: %Schema{type: :string, nullable: true, example: "Production Secrets"},
        description: %Schema{
          type: :string,
          nullable: true,
          example: "Credentials for production MCP servers."
        },
        display_metadata: object_map_schema(%{"label" => "Primary"}),
        metadata: object_map_schema(%{"external_user_id" => "usr_abc123"})
      },
      additionalProperties: true,
      example: create_vault_request_example()
    }
  end

  defp credential_auth_schema do
    %Schema{
      title: "CredentialAuth",
      oneOf: [
        %Schema{
          type: :object,
          properties: %{
            type: %Schema{type: :string, enum: ["static_bearer"], example: "static_bearer"},
            mcp_server_url: %Schema{
              type: :string,
              format: :uri,
              example: "https://docs.example.com/mcp"
            },
            token: %Schema{
              type: :string,
              nullable: true,
              example: "sk-live-secret"
            }
          },
          required: [:type, :mcp_server_url]
        },
        %Schema{
          type: :object,
          properties: %{
            type: %Schema{type: :string, enum: ["mcp_oauth"], example: "mcp_oauth"},
            mcp_server_url: %Schema{
              type: :string,
              format: :uri,
              example: "https://calendar.example.com/mcp"
            },
            access_token: %Schema{
              type: :string,
              nullable: true,
              example: "oauth-access-token"
            },
            refresh:
              object_map_schema(%{
                "token_endpoint" => "https://calendar.example.com/oauth/token",
                "client_id" => "demo-client"
              })
          },
          required: [:type, :mcp_server_url]
        }
      ],
      example: credential_auth_example()
    }
  end

  defp credential_schema do
    %Schema{
      title: "Credential",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "crd_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["credential"], example: "credential"},
        vault_id: %Schema{type: :string, example: "vlt_01JABCDEF1234567890"},
        display_name: %Schema{
          type: :string,
          nullable: true,
          example: "Docs MCP token"
        },
        metadata: object_map_schema(%{"team" => "platform"}),
        auth: ref("CredentialAuth"),
        created_at: datetime_schema("2026-04-12T16:19:00Z"),
        updated_at: datetime_schema("2026-04-12T16:19:00Z")
      },
      required: [:id, :type, :vault_id, :auth],
      additionalProperties: true,
      example: credential_example()
    }
  end

  defp create_credential_request_schema do
    %Schema{
      title: "CreateCredentialRequest",
      type: :object,
      properties: %{
        display_name: %Schema{
          type: :string,
          nullable: true,
          example: "Docs MCP token"
        },
        metadata: object_map_schema(%{"team" => "platform"}),
        auth: ref("CredentialAuth")
      },
      required: [:auth],
      additionalProperties: true,
      example: create_credential_request_example()
    }
  end

  defp update_credential_request_schema do
    %Schema{
      title: "UpdateCredentialRequest",
      type: :object,
      properties: %{
        display_name: %Schema{
          type: :string,
          nullable: true,
          example: "Docs MCP token"
        },
        metadata: object_map_schema(%{"team" => "platform"}),
        auth: ref("CredentialAuth")
      },
      additionalProperties: true,
      example: %{
        "display_name" => "Docs MCP token",
        "auth" => %{"type" => "static_bearer", "token" => "sk-live-rotated"}
      }
    }
  end

  defp session_schema do
    %Schema{
      title: "Session",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "ses_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["session"], example: "session"},
        agent: ref("AgentReference"),
        environment_id: %Schema{type: :string, example: "env_01JABCDEF1234567890"},
        vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          example: ["vlt_01JABCDEF1234567890"]
        },
        title: %Schema{type: :string, nullable: true, example: "Debug auth flow"},
        status: %Schema{type: :string, example: "running"},
        stop_reason: stop_reason_schema(),
        archived_at: datetime_schema(nil, nullable: true),
        created_at: datetime_schema("2026-04-12T16:20:00Z"),
        updated_at: datetime_schema("2026-04-12T16:20:00Z")
      },
      required: [:id, :type, :agent, :environment_id, :vault_ids, :status],
      additionalProperties: true,
      example: session_example()
    }
  end

  defp create_session_request_schema do
    %Schema{
      title: "CreateSessionRequest",
      type: :object,
      properties: %{
        agent: %Schema{
          oneOf: [
            %Schema{type: :string, example: "agt_01JABCDEF1234567890"},
            ref("AgentReference")
          ]
        },
        environment_id: %Schema{type: :string, example: "env_01JABCDEF1234567890"},
        title: %Schema{type: :string, nullable: true, example: "Debug auth flow"},
        vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          example: ["vlt_01JABCDEF1234567890"]
        }
      },
      required: [:agent, :environment_id],
      additionalProperties: true,
      example: create_session_request_example()
    }
  end

  defp session_event_schema do
    %Schema{
      title: "SessionEvent",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "evt_01JABCDEF1234567890"},
        type: %Schema{type: :string, example: "user.message"},
        session_id: %Schema{type: :string, example: "ses_01JABCDEF1234567890"},
        session_thread_id: %Schema{
          type: :string,
          nullable: true,
          example: "thr_01JABCDEF1234567890"
        },
        sequence: %Schema{type: :integer, minimum: 0, example: 12},
        content: object_array_schema(session_event_content_example()),
        payload: object_map_schema(%{}),
        processed_at: datetime_schema(nil, nullable: true),
        stop_reason: stop_reason_schema(),
        created_at: datetime_schema("2026-04-12T16:21:00Z")
      },
      required: [:id, :type, :session_id, :sequence, :content, :payload, :created_at],
      additionalProperties: true,
      example: session_event_example()
    }
  end

  defp session_event_input_schema do
    %Schema{
      title: "SessionEventInput",
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          enum: [
            "user.message",
            "user.interrupt",
            "user.custom_tool_result",
            "user.tool_confirmation"
          ],
          example: "user.message"
        },
        session_thread_id: %Schema{
          type: :string,
          nullable: true,
          example: "thr_01JABCDEF1234567890"
        },
        content: object_array_schema(session_event_content_example()),
        payload: object_map_schema(%{}),
        processed_at: datetime_schema(nil, nullable: true),
        stop_reason: object_map_schema(%{"type" => "end_turn"}, nullable: true),
        custom_tool_use_id: %Schema{
          type: :string,
          nullable: true,
          example: "ctu_01JABCDEF1234567890"
        },
        tool_use_id: %Schema{
          type: :string,
          nullable: true,
          example: "toolu_01JABCDEF1234567890"
        },
        result: %Schema{
          type: :string,
          enum: ["allow", "deny"],
          nullable: true,
          example: "allow"
        },
        deny_message: %Schema{
          type: :string,
          nullable: true,
          example: "This tool is not approved for this environment."
        }
      },
      required: [:type],
      additionalProperties: true,
      example: append_single_event_example()
    }
  end

  defp append_session_events_request_schema do
    %Schema{
      title: "AppendSessionEventsRequest",
      oneOf: [
        ref("SessionEventInput"),
        %Schema{
          type: :object,
          properties: %{
            events: %Schema{
              type: :array,
              minItems: 1,
              items: ref("SessionEventInput"),
              example: [append_single_event_example()]
            }
          },
          required: [:events]
        }
      ],
      example: %{"events" => [append_single_event_example()]}
    }
  end

  defp session_thread_schema do
    %Schema{
      title: "SessionThread",
      type: :object,
      properties: %{
        id: %Schema{type: :string, example: "thr_01JABCDEF1234567890"},
        type: %Schema{type: :string, enum: ["session_thread"], example: "session_thread"},
        session_id: %Schema{type: :string, example: "ses_01JABCDEF1234567890"},
        parent_thread_id: %Schema{
          type: :string,
          nullable: true,
          example: "thr_01JABCDEFPARENT67890"
        },
        role: %Schema{type: :string, example: "assistant"},
        status: %Schema{type: :string, example: "completed"},
        stop_reason: stop_reason_schema(),
        agent: ref("AgentReference"),
        created_at: datetime_schema("2026-04-12T16:22:00Z"),
        updated_at: datetime_schema("2026-04-12T16:22:10Z")
      },
      required: [:id, :type, :session_id, :role, :status, :agent],
      additionalProperties: true,
      example: session_thread_example()
    }
  end

  defp operation(tag, operation_id, summary, opts) do
    %Operation{
      tags: [tag],
      operationId: operation_id,
      summary: summary,
      description: opts[:description],
      parameters: opts[:parameters] || [],
      requestBody: opts[:request_body],
      responses: opts[:responses]
    }
  end

  defp json_request(description, schema_name) do
    Operation.request_body(description, @json, ref(schema_name), required: true)
  end

  defp json_responses(status, description, schema_name, error_codes) do
    error_codes
    |> Enum.reduce(
      %{Integer.to_string(status) => Operation.response(description, @json, ref(schema_name))},
      fn status_code, acc ->
        Map.put(acc, Integer.to_string(status_code), error_response(status_code))
      end
    )
  end

  defp no_content_responses(error_codes) do
    Enum.reduce(
      error_codes,
      %{"204" => Operation.response("No content.", nil, nil)},
      fn status_code, acc ->
        Map.put(acc, Integer.to_string(status_code), error_response(status_code))
      end
    )
  end

  defp event_stream_responses(error_codes) do
    Enum.reduce(
      error_codes,
      %{
        "200" =>
          Operation.response("Server-sent events stream.", @sse, %Schema{
            type: :string,
            example: stream_event_example()
          })
      },
      fn status_code, acc ->
        Map.put(acc, Integer.to_string(status_code), error_response(status_code))
      end
    )
  end

  defp error_response(400) do
    Operation.response("Invalid request.", @json, ref("ErrorEnvelope"),
      example: error_example(400)
    )
  end

  defp error_response(401) do
    Operation.response("Authentication required.", @json, ref("ErrorEnvelope"),
      example: error_example(401)
    )
  end

  defp error_response(403) do
    Operation.response("Permission denied.", @json, ref("ErrorEnvelope"),
      example: error_example(403)
    )
  end

  defp error_response(404) do
    Operation.response("Resource not found.", @json, ref("ErrorEnvelope"),
      example: error_example(404)
    )
  end

  defp error_response(409) do
    Operation.response("Request conflict.", @json, ref("ErrorEnvelope"),
      example: error_example(409)
    )
  end

  defp error_response(_status_code) do
    Operation.response("Unexpected API error.", @json, ref("ErrorEnvelope"),
      example: error_example(500)
    )
  end

  defp id_param(resource_name) do
    Operation.parameter(:id, :path, :string, "#{resource_name} ID.")
  end

  defp vault_id_param do
    Operation.parameter(:vault_id, :path, :string, "Vault ID.")
  end

  defp thread_id_param do
    Operation.parameter(:thread_id, :path, :string, "Session thread ID.")
  end

  defp limit_param do
    Operation.parameter(
      :limit,
      :query,
      %Schema{type: :integer, minimum: 1, maximum: 100, example: 20},
      "Maximum number of events to return."
    )
  end

  defp after_param do
    Operation.parameter(
      :after,
      :query,
      %Schema{type: :integer, minimum: -1, example: 12},
      "Only return or stream events after this sequence number."
    )
  end

  defp list_envelope_schema(title, item_schema, example_items) do
    %Schema{
      title: title,
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: item_schema, example: example_items},
        has_more: %Schema{type: :boolean, example: false}
      },
      required: [:data, :has_more],
      example: %{"data" => example_items, "has_more" => false}
    }
  end

  defp model_schema do
    %Schema{
      oneOf: [
        %Schema{type: :string, example: "claude-sonnet-4-6"},
        ref("StructuredModel")
      ],
      example: %{"provider" => "anthropic", "id" => "claude-sonnet-4-6"}
    }
  end

  defp object_map_schema(example, opts \\ []) do
    %Schema{
      type: :object,
      additionalProperties: true,
      example: example,
      nullable: Keyword.get(opts, :nullable, false)
    }
  end

  defp object_array_schema(example) do
    %Schema{
      type: :array,
      items: %Schema{type: :object, additionalProperties: true},
      example: example
    }
  end

  defp datetime_schema(example, opts \\ []) do
    %Schema{
      type: :string,
      format: :"date-time",
      example: example,
      nullable: Keyword.get(opts, :nullable, false)
    }
  end

  defp stop_reason_schema do
    %Schema{
      oneOf: [
        %Schema{type: :string, example: "end_turn"},
        object_map_schema(%{"type" => "end_turn"})
      ],
      nullable: true,
      example: %{"type" => "end_turn"}
    }
  end

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  defp agent_example do
    %{
      "id" => "agt_01JABCDEF1234567890",
      "type" => "agent",
      "name" => "Coding Assistant",
      "model" => %{"provider" => "anthropic", "id" => "claude-sonnet-4-6"},
      "system" => "You are a senior software engineer.",
      "tools" => agent_tools_example(),
      "mcp_servers" => agent_mcp_servers_example(),
      "skills" => [],
      "callable_agents" => [],
      "description" => "Handles day-to-day engineering tasks.",
      "metadata" => agent_metadata_example(),
      "version" => 1,
      "archived_at" => nil,
      "created_at" => "2026-04-12T16:15:00Z",
      "updated_at" => "2026-04-12T16:15:00Z"
    }
  end

  defp agent_version_example do
    agent_example()
    |> Map.put("version", 2)
    |> Map.put("updated_at", "2026-04-13T08:00:00Z")
  end

  defp create_agent_request_example do
    %{
      "name" => "Coding Assistant",
      "description" => "Handles day-to-day engineering tasks.",
      "model" => %{"provider" => "anthropic", "id" => "claude-sonnet-4-6"},
      "system" => "You are a senior software engineer.",
      "tools" => agent_tools_example(),
      "mcp_servers" => agent_mcp_servers_example(),
      "metadata" => agent_metadata_example()
    }
  end

  defp agent_tools_example do
    [
      %{
        "type" => "agent_toolset_20260401",
        "configs" => %{
          "read" => %{"permission_policy" => "always_allow"},
          "bash" => %{"permission_policy" => "always_ask"}
        }
      }
    ]
  end

  defp agent_mcp_servers_example do
    [
      %{
        "name" => "docs",
        "type" => "url",
        "url" => "https://docs.example.com/mcp"
      }
    ]
  end

  defp agent_metadata_example do
    %{"team" => "platform"}
  end

  defp skill_example do
    %{
      "id" => "skl_01JABCDEF1234567890",
      "type" => "skill",
      "skill_type" => "custom",
      "name" => "docx",
      "description" => "Summarize doc changes into a concise status update.",
      "version" => 1,
      "metadata" => %{"team" => "platform"},
      "version_metadata" => %{"owner" => "platform"},
      "allowed_tools" => ["read", "web_search"],
      "manifest" => %{"name" => "docx", "version" => "0.1.0"},
      "source_path" => "/Users/demo/skills/docx/SKILL.md",
      "body" => "Read the supplied docs and return the salient changes.",
      "archived_at" => nil,
      "created_at" => "2026-04-12T16:16:00Z",
      "updated_at" => "2026-04-12T16:16:00Z"
    }
  end

  defp skill_version_example do
    skill_example()
    |> Map.put("version", 2)
    |> Map.put("updated_at", "2026-04-13T08:10:00Z")
  end

  defp create_skill_request_example do
    %{
      "type" => "custom",
      "name" => "docx",
      "description" => "Summarize doc changes into a concise status update.",
      "body" => "Read the supplied docs and return the salient changes.",
      "allowed_tools" => ["read", "web_search"],
      "manifest" => %{"name" => "docx", "version" => "0.1.0"},
      "metadata" => %{"team" => "platform"},
      "version_metadata" => %{"owner" => "platform"}
    }
  end

  defp environment_schema_example_metadata do
    %{"team" => "ops"}
  end

  defp environment_config_example do
    %{"type" => "cloud", "networking" => %{"type" => "restricted"}}
  end

  defp environment_example do
    %{
      "id" => "env_01JABCDEF1234567890",
      "type" => "environment",
      "name" => "Restricted Demo Sandbox",
      "description" => "Reusable sandbox for API-launched sessions.",
      "config" => environment_config_example(),
      "metadata" => environment_schema_example_metadata(),
      "archived_at" => nil,
      "created_at" => "2026-04-12T16:17:00Z",
      "updated_at" => "2026-04-12T16:17:00Z"
    }
  end

  defp create_environment_request_example do
    %{
      "name" => "Restricted Demo Sandbox",
      "description" => "Reusable sandbox for API-launched sessions.",
      "config" => environment_config_example(),
      "metadata" => environment_schema_example_metadata()
    }
  end

  defp vault_example do
    %{
      "id" => "vlt_01JABCDEF1234567890",
      "type" => "vault",
      "name" => "production-secrets",
      "display_name" => "Production Secrets",
      "description" => "Credentials for production MCP servers.",
      "display_metadata" => %{"display_name" => "Production Secrets", "label" => "Primary"},
      "metadata" => %{"external_user_id" => "usr_abc123"},
      "created_at" => "2026-04-12T16:18:00Z",
      "updated_at" => "2026-04-12T16:18:00Z"
    }
  end

  defp create_vault_request_example do
    %{
      "display_name" => "Production Secrets",
      "description" => "Credentials for production MCP servers.",
      "display_metadata" => %{"label" => "Primary"},
      "metadata" => %{"external_user_id" => "usr_abc123"}
    }
  end

  defp credential_auth_example do
    %{
      "type" => "static_bearer",
      "mcp_server_url" => "https://docs.example.com/mcp"
    }
  end

  defp credential_example do
    %{
      "id" => "crd_01JABCDEF1234567890",
      "type" => "credential",
      "vault_id" => "vlt_01JABCDEF1234567890",
      "display_name" => "Docs MCP token",
      "metadata" => %{"team" => "platform"},
      "auth" => credential_auth_example(),
      "created_at" => "2026-04-12T16:19:00Z",
      "updated_at" => "2026-04-12T16:19:00Z"
    }
  end

  defp create_credential_request_example do
    %{
      "display_name" => "Docs MCP token",
      "metadata" => %{"team" => "platform"},
      "auth" => %{
        "type" => "static_bearer",
        "mcp_server_url" => "https://docs.example.com/mcp",
        "token" => "sk-live-secret"
      }
    }
  end

  defp session_example do
    %{
      "id" => "ses_01JABCDEF1234567890",
      "type" => "session",
      "agent" => %{
        "type" => "agent",
        "id" => "agt_01JABCDEF1234567890",
        "version" => 1
      },
      "environment_id" => "env_01JABCDEF1234567890",
      "vault_ids" => ["vlt_01JABCDEF1234567890"],
      "title" => "Debug auth flow",
      "status" => "running",
      "stop_reason" => nil,
      "archived_at" => nil,
      "created_at" => "2026-04-12T16:20:00Z",
      "updated_at" => "2026-04-12T16:20:00Z"
    }
  end

  defp create_session_request_example do
    %{
      "agent" => %{
        "type" => "agent",
        "id" => "agt_01JABCDEF1234567890",
        "version" => 1
      },
      "environment_id" => "env_01JABCDEF1234567890",
      "title" => "Debug auth flow",
      "vault_ids" => ["vlt_01JABCDEF1234567890"]
    }
  end

  defp session_event_content_example do
    [%{"type" => "input_text", "text" => "Summarize the failing auth flow."}]
  end

  defp session_event_example do
    %{
      "id" => "evt_01JABCDEF1234567890",
      "type" => "user.message",
      "session_id" => "ses_01JABCDEF1234567890",
      "session_thread_id" => "thr_01JABCDEF1234567890",
      "sequence" => 12,
      "content" => session_event_content_example(),
      "payload" => %{},
      "processed_at" => nil,
      "stop_reason" => nil,
      "created_at" => "2026-04-12T16:21:00Z"
    }
  end

  defp append_single_event_example do
    %{
      "type" => "user.message",
      "content" => session_event_content_example()
    }
  end

  defp session_thread_example do
    %{
      "id" => "thr_01JABCDEF1234567890",
      "type" => "session_thread",
      "session_id" => "ses_01JABCDEF1234567890",
      "parent_thread_id" => nil,
      "role" => "assistant",
      "status" => "completed",
      "stop_reason" => %{"type" => "end_turn"},
      "agent" => %{
        "type" => "agent",
        "id" => "agt_01JABCDEF1234567890",
        "version" => 1
      },
      "created_at" => "2026-04-12T16:22:00Z",
      "updated_at" => "2026-04-12T16:22:10Z"
    }
  end

  defp error_example(400) do
    %{
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "Request body must be a JSON object."
      }
    }
  end

  defp error_example(401) do
    %{
      "error" => %{
        "type" => "authentication_error",
        "message" => "x-api-key header is required."
      }
    }
  end

  defp error_example(403) do
    %{
      "error" => %{
        "type" => "permission_error",
        "message" => "Request is not permitted."
      }
    }
  end

  defp error_example(404) do
    %{
      "error" => %{
        "type" => "not_found_error",
        "message" => "Resource not found."
      }
    }
  end

  defp error_example(409) do
    %{
      "error" => %{
        "type" => "conflict_error",
        "message" => "workspace already has an active session"
      }
    }
  end

  defp error_example(_status_code) do
    %{
      "error" => %{
        "type" => "api_error",
        "message" => "Unexpected API error."
      }
    }
  end

  defp stream_event_example do
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\"}}\n\n"
  end
end
