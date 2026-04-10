defmodule JidoManagedAgents.PlatformArchitectureTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgents.Platform.Architecture

  @expected_domains [
    JidoManagedAgents.Accounts,
    JidoManagedAgents.Agents,
    JidoManagedAgents.Sessions,
    JidoManagedAgents.Integrations
  ]

  test "registers the platform Ash domains in config and code" do
    assert Application.fetch_env!(:jido_managed_agents, :ash_domains) == @expected_domains
    assert Architecture.domain_modules() == @expected_domains
  end

  test "defines domain modules with the persisted foundation resources in place" do
    assert Ash.Domain.Info.resources(JidoManagedAgents.Accounts) == [
             JidoManagedAgents.Accounts.Token,
             JidoManagedAgents.Accounts.User,
             JidoManagedAgents.Accounts.ApiKey
           ]

    assert Ash.Domain.Info.resources(JidoManagedAgents.Agents) == [
             JidoManagedAgents.Agents.Agent,
             JidoManagedAgents.Agents.AgentVersion,
             JidoManagedAgents.Agents.AgentVersionSkill,
             JidoManagedAgents.Agents.AgentVersionCallableAgent,
             JidoManagedAgents.Agents.Environment,
             JidoManagedAgents.Agents.Skill,
             JidoManagedAgents.Agents.SkillVersion
           ]

    assert Ash.Domain.Info.resources(JidoManagedAgents.Sessions) == [
             JidoManagedAgents.Sessions.Workspace,
             JidoManagedAgents.Sessions.Session,
             JidoManagedAgents.Sessions.SessionVault,
             JidoManagedAgents.Sessions.SessionThread,
             JidoManagedAgents.Sessions.SessionEvent
           ]

    assert Ash.Domain.Info.resources(JidoManagedAgents.Integrations) == [
             JidoManagedAgents.Integrations.Vault,
             JidoManagedAgents.Integrations.Credential
           ]
  end

  test "documents resource ownership and cross-domain boundaries" do
    blueprints = Architecture.domain_blueprints()

    assert Enum.find(blueprints, &(&1.domain == JidoManagedAgents.Agents)).owned_resources == [
             JidoManagedAgents.Agents.Agent,
             JidoManagedAgents.Agents.AgentVersion,
             JidoManagedAgents.Agents.AgentVersionSkill,
             JidoManagedAgents.Agents.AgentVersionCallableAgent,
             JidoManagedAgents.Agents.Environment,
             JidoManagedAgents.Agents.Skill,
             JidoManagedAgents.Agents.SkillVersion
           ]

    assert Enum.find(blueprints, &(&1.domain == JidoManagedAgents.Sessions)).cross_domain_reference_strategy ==
             [
               "Session records reference Agents and Integrations resources through explicit foreign keys and join resources.",
               "Ownership remains rooted in Accounts.User even when runtime rows also point at agent, environment, workspace, or vault records."
             ]

    assert Architecture.ownership_conventions() == %{
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
  end

  test "standardizes Postgres-backed field conventions" do
    assert Architecture.shared_resource_conventions() == %{
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
               semantics:
                 "soft-delete tombstone for runtime-facing records that must remain queryable"
             },
             timestamp_preference: %{
               preferred_create_field: :created_at,
               rejected_alias: :inserted_at
             }
           }
  end

  test "documents the authorization foundation for later resource stories" do
    assert Architecture.authorization_foundation() == %{
             actor_roles: [:member, :platform_admin],
             authorizer: Ash.Policy.Authorizer,
             owner_policy_pattern:
               "owner-scoped access is expressed with belongs_to :user Ash policies",
             admin_policy_pattern:
               "platform_admin bypasses owner-scoped policies for support and seeding operations",
             api_key_inheritance:
               "API keys authenticate as the owning user actor and therefore inherit that user's Ash policies.",
             actor_entry_points: [:browser, :api, :live_view, :runtime]
           }
  end

  test "documents the shared secret encryption foundation for later resource stories" do
    assert Architecture.secret_encryption_foundation() == %{
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
  end

  test "documents how vaults and credentials fit into the secret model and later session resolution flow" do
    assert Architecture.integrations_secret_model() == %{
             vault_resource: JidoManagedAgents.Integrations.Vault,
             vault_scope:
               "Vault is a user-owned container for non-secret secret-routing metadata only.",
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
  end

  test "distinguishes normalized relationships from inline Anthropic-shaped fragments" do
    assert Architecture.normalized_relationship_concepts() == [
             %{name: :agent_versions, kind: :resource},
             %{name: :skill_versions, kind: :resource},
             %{name: :agent_version_skills, kind: :join_resource},
             %{name: :agent_version_callable_agents, kind: :join_resource},
             %{name: :session_vaults, kind: :join_resource},
             %{name: :session_threads, kind: :resource},
             %{name: :session_events, kind: :resource},
             %{name: :credentials, kind: :resource}
           ]

    assert Architecture.inline_versioned_parent_fragments() == [
             :model,
             :system,
             :tools,
             :mcp_servers,
             :tool_choice,
             :response_format,
             :metadata
           ]
  end

  test "exposes developer-facing architecture docs in the repo" do
    readme = project_file!("README.md")
    architecture_guide = project_file!("docs/ash_platform_architecture.md")

    assert readme =~ "docs/ash_platform_architecture.md"
    assert readme =~ "JidoManagedAgents.Platform.Architecture"
    assert readme =~ "AshCloak/Cloak secret infrastructure"

    assert architecture_guide =~ "## Domain Split"
    assert architecture_guide =~ "### Accounts"
    assert architecture_guide =~ "### Agents"
    assert architecture_guide =~ "### Sessions"
    assert architecture_guide =~ "### Integrations"
    assert architecture_guide =~ "AshPostgres.DataLayer"
    assert architecture_guide =~ "## Authorization And RBAC Foundation"
    assert architecture_guide =~ "`platform_admin`"
    assert architecture_guide =~ "API keys do not introduce a second role"
    assert architecture_guide =~ "created_at"
    assert architecture_guide =~ "updated_at"
    assert architecture_guide =~ "archived_at"
    assert architecture_guide =~ "deleted_at"
    assert architecture_guide =~ "AgentVersionSkill"
    assert architecture_guide =~ "Anthropic-shaped config fragments"
    assert architecture_guide =~ "## Secret Encryption Infrastructure"
    assert architecture_guide =~ "JidoManagedAgents.Vault"
    assert architecture_guide =~ "AshCloak"
    assert architecture_guide =~ "JIDO_MANAGED_AGENTS_CLOAK_KEY"
    assert architecture_guide =~ "## Vault Foundation Resource"
    assert architecture_guide =~ "JidoManagedAgents.Integrations.Vault"
    assert architecture_guide =~ "## Credential Foundation Resource"
    assert architecture_guide =~ "JidoManagedAgents.Integrations.Credential"
    assert architecture_guide =~ "access_token"
    assert architecture_guide =~ "client_secret"
    assert architecture_guide =~ "mcp_server_url"
    assert architecture_guide =~ "write-only action arguments"
    assert architecture_guide =~ "SessionVault"
    assert architecture_guide =~ "position"
  end

  defp project_file!(relative_path) do
    relative_path
    |> Path.expand(File.cwd!())
    |> File.read!()
  end
end
