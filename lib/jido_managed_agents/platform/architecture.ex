defmodule JidoManagedAgents.Platform.Architecture do
  @moduledoc """
  Defines the Ash platform boundary for the managed-agents example.

  This module is the code-level source of truth for `ST-PLAT-001`,
  `ST-PLAT-002`, `ST-PLAT-004`, `ST-PLAT-005`, and `ST-PLAT-006`. It captures
  the intended domain split, user ownership rules, persistence conventions, the
  app-level secret encryption foundation, the vault and credential secret
  model, and the line between normalized relationships and embedded
  Anthropic-compatible config fragments before later platform resources are
  implemented.
  """

  @domain_blueprints [
    %{
      domain: JidoManagedAgents.Accounts,
      owned_resources: [
        JidoManagedAgents.Accounts.User,
        JidoManagedAgents.Accounts.ApiKey,
        JidoManagedAgents.Accounts.Token
      ],
      responsibilities: [
        "browser and API authentication",
        "actor identity and ownership root",
        "API key issuance and token lifecycle"
      ],
      cross_domain_reference_strategy: [
        "All mutable managed-agents resources reference Accounts.User as their owner.",
        "Feature domains use Accounts for actor propagation and ownership, not for catalog or runtime data."
      ]
    },
    %{
      domain: JidoManagedAgents.Agents,
      owned_resources: [
        JidoManagedAgents.Agents.Agent,
        JidoManagedAgents.Agents.AgentVersion,
        JidoManagedAgents.Agents.AgentVersionSkill,
        JidoManagedAgents.Agents.AgentVersionCallableAgent,
        JidoManagedAgents.Agents.Environment,
        JidoManagedAgents.Agents.Skill,
        JidoManagedAgents.Agents.SkillVersion
      ],
      responsibilities: [
        "versioned agent catalog",
        "Anthropic-compatible agent serialization",
        "reusable environment and skill definitions"
      ],
      cross_domain_reference_strategy: [
        "Every resource belongs_to :user to preserve per-user ownership.",
        "Sessions reference agent-side resources by foreign key instead of copying normalized relationships into runtime blobs."
      ]
    },
    %{
      domain: JidoManagedAgents.Sessions,
      owned_resources: [
        JidoManagedAgents.Sessions.Workspace,
        JidoManagedAgents.Sessions.Session,
        JidoManagedAgents.Sessions.SessionVault,
        JidoManagedAgents.Sessions.SessionThread,
        JidoManagedAgents.Sessions.SessionEvent
      ],
      responsibilities: [
        "workspace reuse and session lifecycle",
        "append-only execution history",
        "runtime-facing joins into agents and integrations"
      ],
      cross_domain_reference_strategy: [
        "Session records reference Agents and Integrations resources through explicit foreign keys and join resources.",
        "Ownership remains rooted in Accounts.User even when runtime rows also point at agent, environment, workspace, or vault records."
      ]
    },
    %{
      domain: JidoManagedAgents.Integrations,
      owned_resources: [
        JidoManagedAgents.Integrations.Vault,
        JidoManagedAgents.Integrations.Credential
      ],
      responsibilities: [
        "per-user secret containers",
        "encrypted credential persistence",
        "runtime credential resolution for MCP and tool execution"
      ],
      cross_domain_reference_strategy: [
        "Vault and Credential stay isolated from the Agents domain and are attached to sessions through SessionVault joins.",
        "Runtime code resolves integrations through Ash relationships instead of embedding secrets on agents or sessions."
      ]
    }
  ]

  @ownership_conventions %{
    owner_resource: JidoManagedAgents.Accounts.User,
    owner_relationship: :user,
    rule:
      "Every mutable managed-agents resource belongs_to :user with allow_nil? false and is filtered through the owning user.",
    mutable_resources: [
      JidoManagedAgents.Agents.Agent,
      JidoManagedAgents.Agents.AgentVersion,
      JidoManagedAgents.Agents.AgentVersionSkill,
      JidoManagedAgents.Agents.AgentVersionCallableAgent,
      JidoManagedAgents.Agents.Environment,
      JidoManagedAgents.Agents.Skill,
      JidoManagedAgents.Agents.SkillVersion,
      JidoManagedAgents.Sessions.Workspace,
      JidoManagedAgents.Sessions.Session,
      JidoManagedAgents.Sessions.SessionVault,
      JidoManagedAgents.Sessions.SessionThread,
      JidoManagedAgents.Sessions.SessionEvent,
      JidoManagedAgents.Integrations.Vault,
      JidoManagedAgents.Integrations.Credential
    ]
  }

  @authorization_foundation %{
    actor_roles: [:member, :platform_admin],
    authorizer: Ash.Policy.Authorizer,
    owner_policy_pattern: "owner-scoped access is expressed with belongs_to :user Ash policies",
    admin_policy_pattern:
      "platform_admin bypasses owner-scoped policies for support and seeding operations",
    api_key_inheritance:
      "API keys authenticate as the owning user actor and therefore inherit that user's Ash policies.",
    actor_entry_points: [:browser, :api, :live_view, :runtime]
  }

  @shared_resource_conventions %{
    data_layer: AshPostgres.DataLayer,
    persistence: :postgres,
    repo: JidoManagedAgents.Repo,
    id: %{name: :id, type: :uuid, dsl: :uuid_primary_key},
    metadata: %{name: :metadata, type: :map, default: %{}},
    created_at: %{name: :created_at, type: :utc_datetime_usec},
    updated_at: %{name: :updated_at, type: :utc_datetime_usec},
    archived_at: %{
      name: :archived_at,
      type: :utc_datetime_usec,
      optional?: true,
      semantics: "reversible archive marker for resources that support archiving"
    },
    deleted_at: %{
      name: :deleted_at,
      type: :utc_datetime_usec,
      optional?: true,
      semantics: "soft-delete tombstone for runtime-facing records that must remain queryable"
    },
    timestamp_preference: %{
      preferred_create_field: :created_at,
      rejected_alias: :inserted_at
    }
  }

  @normalized_relationship_concepts [
    %{name: :agent_versions, kind: :resource},
    %{name: :skill_versions, kind: :resource},
    %{name: :agent_version_skills, kind: :join_resource},
    %{name: :agent_version_callable_agents, kind: :join_resource},
    %{name: :session_vaults, kind: :join_resource},
    %{name: :session_threads, kind: :resource},
    %{name: :session_events, kind: :resource},
    %{name: :credentials, kind: :resource}
  ]

  @inline_versioned_parent_fragments [
    :model,
    :system,
    :tools,
    :mcp_servers,
    :tool_choice,
    :response_format,
    :metadata
  ]

  @stack_choices [
    %{library: Ash, role: "domains, resources, actions, calculations, validations, and policies"},
    %{
      library: AshPostgres,
      role: "Postgres data layer for every persisted managed-agents resource"
    },
    %{library: AshAuthentication, role: "browser, token, and API key authentication"},
    %{library: AshAuthenticationPhoenix, role: "Phoenix actor resolution and session helpers"},
    %{library: AshPhoenix, role: "resource-backed forms and LiveView workflows"},
    %{
      library: AshJsonApi,
      role: "internal app JSON:API flows while the public `/v1` API stays custom"
    }
  ]

  @secret_encryption_foundation %{
    vault: JidoManagedAgents.Vault,
    ash_extension: AshCloak,
    runtime_config_key: :secret_encryption,
    env_var: "JIDO_MANAGED_AGENTS_CLOAK_KEY",
    environment_key_strategy: %{
      dev:
        "Uses JIDO_MANAGED_AGENTS_CLOAK_KEY when present and otherwise derives a deterministic local development key.",
      test:
        "Uses JIDO_MANAGED_AGENTS_CLOAK_KEY when present and otherwise derives a deterministic test key for repeatable test runs.",
      prod: "Requires JIDO_MANAGED_AGENTS_CLOAK_KEY to be present before boot."
    },
    ash_resource_pattern: [
      "Add `extensions: [AshCloak]` to the resource.",
      "Configure `cloak do` with `vault JidoManagedAgents.Vault` and only the secret-bearing attributes.",
      "Keep queryable routing and ownership fields as normal Postgres attributes; reserve AshCloak for secret-bearing values."
    ]
  }

  @integrations_secret_model %{
    vault_resource: JidoManagedAgents.Integrations.Vault,
    vault_scope: "Vault is a user-owned container for non-secret secret-routing metadata only.",
    vault_non_secret_fields: [:name, :description, :display_metadata, :metadata],
    credential_resource: JidoManagedAgents.Integrations.Credential,
    credential_scope:
      "Credential is the vault child resource that stores encrypted secret payloads plus queryable routing fields.",
    credential_queryable_fields: [
      :vault_id,
      :type,
      :mcp_server_url,
      :token_endpoint,
      :client_id,
      :metadata
    ],
    credential_encrypted_fields: [:access_token, :refresh_token, :client_secret],
    credential_field_rationale: [
      "Queryable routing fields stay as normal Postgres columns so vault-local lookup, identities, and owner-scoped policies remain filterable.",
      "Secret-bearing values are encrypted with AshCloak and only surface as write-only action inputs plus on-demand calculations when runtime code explicitly loads them."
    ],
    credential_match_identity: [:vault_id, :type, :mcp_server_url],
    session_resolution_flow: [
      "Sessions attach vault access through ordered SessionVault join rows instead of embedding opaque secret blobs on Session.",
      "Runtime credential lookup walks SessionVault rows in ascending position, then matches credentials within each Vault by queryable routing fields such as MCP server URL.",
      "Only the matched credential's encrypted secret attributes are decrypted at runtime for tool or MCP execution."
    ],
    normalized_runtime_reference: %{
      join_resource: JidoManagedAgents.Sessions.SessionVault,
      parent_foreign_key: :vault_id
    }
  }

  def domain_modules do
    Enum.map(@domain_blueprints, & &1.domain)
  end

  def domain_blueprints, do: @domain_blueprints

  def ownership_conventions, do: @ownership_conventions

  def authorization_foundation, do: @authorization_foundation

  def shared_resource_conventions, do: @shared_resource_conventions

  def normalized_relationship_concepts, do: @normalized_relationship_concepts

  def inline_versioned_parent_fragments, do: @inline_versioned_parent_fragments

  def stack_choices, do: @stack_choices

  def secret_encryption_foundation, do: @secret_encryption_foundation

  def integrations_secret_model, do: @integrations_secret_model
end
