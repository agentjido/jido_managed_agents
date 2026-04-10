# Ash Platform Architecture

This guide captures the architecture decisions for `ST-PLAT-001`,
`ST-PLAT-002`, `ST-PLAT-004`, `ST-PLAT-005`, and `ST-PLAT-006`. It defines the
Ash domain split, cross-domain relationship strategy, ownership rules, shared
authorization model, the shared secret-encryption foundation, the vault and
credential secret model, and shared Postgres conventions that later platform
stories build on.

## Why This Split Exists

The project needs a durable persisted model before agent, session, and secret
resources land. The split keeps responsibilities clear:

- `Accounts` owns authentication, actor identity, and the `User` ownership root.
- `Agents` owns the reusable catalog and Anthropic-compatible agent definitions.
- `Sessions` owns runtime execution state, workspace reuse, and append-only
  session history.
- `Integrations` owns per-user secret containers and credentials.

That separation keeps authentication concerns out of runtime resources, prevents
secrets from leaking into agent definitions, and gives each future story a clear
place to add Ash resources.

## Domain Split

### Accounts

Resources:

- `User`
- `ApiKey`
- `Token`

Responsibilities:

- Browser authentication
- API-key authentication
- Actor propagation and ownership root

Cross-domain references:

- Other domains reference `Accounts.User` as the owner of every mutable
  managed-agents resource.
- Feature resources do not embed account data; they use explicit foreign keys
  and Ash relationships back to `User`.

### Agents

Planned resources:

- `Agent`
- `AgentVersion`
- `AgentVersionSkill`
- `AgentVersionCallableAgent`
- `Environment`
- `Skill`
- `SkillVersion`

Responsibilities:

- Versioned reusable agent catalog
- Anthropic-compatible serialization and YAML alignment
- Reusable environment and skill definitions

Cross-domain references:

- Every mutable resource belongs to `User`.
- Runtime records in `Sessions` reference agents, versions, and environments by
  foreign key instead of copying normalized relationships into opaque blobs.

### Sessions

Planned resources:

- `Workspace`
- `Session`
- `SessionVault`
- `SessionThread`
- `SessionEvent`

Responsibilities:

- Workspace reuse and active-session lifecycle
- Append-only execution history
- Runtime joins into agent and integration resources

Cross-domain references:

- `Session` references `Agent`, `AgentVersion`, `Environment`, and `Workspace`
  directly.
- Vault attachment is modeled as the ordered join resource `SessionVault`
  instead of embedding vault details on the session.
- Ownership remains rooted in `User` even when runtime rows point at multiple
  parent resources.

### Integrations

Planned resources:

- `Vault`
- `Credential`

Responsibilities:

- Per-user secret containers
- Encrypted credential persistence
- Credential resolution for MCP and tool execution

Cross-domain references:

- Agents do not own credentials directly.
- Sessions attach vault access through `SessionVault`, which keeps runtime
  secret access explicit and queryable.

## Ownership And Auth Scope

Ownership is standardized around `Accounts.User`.

- Every mutable managed-agents resource is scoped to a `User`.
- The canonical relationship is `belongs_to :user`.
- `allow_nil? false` is the default for user ownership on mutable feature
  resources.
- Join resources stay user-scoped as well, either through their own `user_id`
  or through owned parents that are already filtered by the owning `User`.
- API keys inherit the permissions of their owning user rather than creating a
  second tenancy model.

This keeps multi-user isolation consistent across browser flows, API-key access,
Ash policies, and runtime entry points.

## Authorization And RBAC Foundation

The v1 role model on the authenticated actor is intentionally small:

- `member`
- `platform_admin`

Authorization is expressed through `Ash.Policy.Authorizer` and reusable Ash
policy patterns instead of controller-specific branching.

- Owner-scoped resources use `belongs_to :user` and owner policies for create,
  read, update, and destroy actions.
- `platform_admin` bypasses those owner-scoped policies for support, seeding,
  and OSS-demo administration workflows.
- Browser auth, bearer auth, API-key auth, LiveViews, and runtime Ash/Jido
  entry points all resolve one Ash actor shape before they invoke Ash actions.
- API keys do not introduce a second role or tenancy model. They authenticate
  as the owning `User`, so an API key inherits the exact Ash permissions of its
  owner.

## Persistence And Ash Stack Choices

Persisted managed-agents resources use the Ash stack directly:

- `Ash` for domains, resources, relationships, actions, validations, and
  policies
- `AshPostgres.DataLayer` for all persisted managed-agents resources
- `AshAuthentication` and `AshAuthenticationPhoenix` for actor resolution and
  authentication
- `AshPhoenix` for future resource-backed LiveView workflows
- `AshJsonApi` for internal app flows when useful, while the public `/v1`
  surface remains Anthropic-shaped and custom

Postgres is the single persistence backend for persisted managed-agents
resources. Jido processes hold execution state, but Ash resources in Postgres
are the source of truth.

## Secret Encryption Infrastructure

`ST-PLAT-004` establishes the app-level encryption building block before `Vault`
and `Credential` resources land.

- `JidoManagedAgents.Vault` is the shared `Cloak.Vault` for encrypted Ash
  attributes across future credential types.
- Runtime config reads the Base64-encoded
  `JIDO_MANAGED_AGENTS_CLOAK_KEY` environment variable when present.
- Development falls back to a deterministic local key so the app boots without
  secret setup during local work.
- Test falls back to a deterministic test key so encrypted-attribute tests are
  repeatable in CI and local runs.
- Production requires `JIDO_MANAGED_AGENTS_CLOAK_KEY` and fails fast if it is
  missing.

Ash resources opt into encrypted attributes with `AshCloak`:

```elixir
defmodule MyApp.Integrations.Credential do
  use Ash.Resource, extensions: [AshCloak]

  cloak do
    vault JidoManagedAgents.Vault
    attributes [:access_token, :refresh_token, :client_secret]
  end
end
```

Use `AshCloak` only for secret-bearing values. Queryable routing fields such as
credential `type`, ownership references, or an MCP server URL should remain
normal Postgres attributes so filters, identities, and policies stay queryable.

## Vault Foundation Resource

`ST-PLAT-005` establishes the persisted container around future credentials.

- `JidoManagedAgents.Integrations.Vault` is a first-class Ash resource in the
  `Integrations` domain backed by Postgres.
- `Vault` belongs to `Accounts.User` and uses the same owner-or-admin Ash
  policies as the catalog resources.
- `Vault` stores only non-secret container fields:
  - `name`
  - `description`
  - `display_metadata`
  - `metadata`
- `Vault` does not use `AshCloak`, because the vault itself is not the secret
  payload. Secret-bearing attributes live on the child `Credential` resource.

## Credential Foundation Resource

`ST-PLAT-006` adds the persisted child resource that carries secret material.

- `JidoManagedAgents.Integrations.Credential` belongs to
  `JidoManagedAgents.Integrations.Vault`.
- Queryable fields stay as normal Postgres columns:
  - `vault_id`
  - `type`
  - `mcp_server_url`
  - `token_endpoint`
  - `client_id`
  - `metadata`
- Encrypted fields opt into `AshCloak` and are stored as ciphertext columns:
  - `access_token`
  - `refresh_token`
  - `client_secret`
- The resource identity keys on `vault_id`, `type`, and `mcp_server_url`, so
  vault-local credential matching stays efficient without decrypting any secret
  data.
- Default serialization exposes the queryable public attributes only. Secret
  inputs are accepted on create and update as write-only action arguments and
  only decrypt when runtime code explicitly loads them.

### Session Credential Resolution Flow

- Session creation accepts Anthropic-style `vault_ids`, but persistence keeps
  those references normalized through ordered `SessionVault` join rows instead
  of embedding vault state on `Session`.
- Runtime resolution walks `SessionVault` rows in ascending `position` so vault
  precedence is explicit and queryable.
- Within each referenced vault, the runtime matches credentials by queryable
  routing fields such as MCP server URL.
- Only the matching credential's encrypted attributes are decrypted, and only
  when MCP or tool execution actually needs them.

## Shared Resource Conventions

Unless a third-party Ash extension requires otherwise, persisted managed-agents
resources follow these conventions:

- `id`: `uuid_primary_key :id`
- `metadata`: `attribute :metadata, :map` with `%{}` as the default
- `created_at`: preferred create timestamp field for new managed-agents
  resources
- `updated_at`: standard update timestamp field
- `archived_at`: optional reversible archive marker for catalog resources
- `deleted_at`: optional soft-delete tombstone for runtime-facing records that
  must remain queryable

`created_at` is preferred over `inserted_at` for new managed-agents resources so
the Ash model reads consistently across API payloads, docs, and policies.

## Relationship Strategy

Real relationships are normalized in Postgres instead of being left implicit in
maps or YAML blobs.

These concepts must be normalized as resources or join resources:

- Immutable version records such as `AgentVersion` and `SkillVersion`
- Join records such as `AgentVersionSkill`, `AgentVersionCallableAgent`, and
  `SessionVault`
- Runtime history resources such as `SessionThread` and `SessionEvent`
- Secret containers and credentials such as `Vault` and `Credential`

These Anthropic-shaped config fragments may remain versioned fields on the
parent resource when keeping them embedded preserves compatibility cleanly:

- `model`
- `system`
- `tools`
- `mcp_servers`
- `tool_choice`
- `response_format`
- `metadata`

The rule is simple: use normalized Ash relationships for things that need
identity, reuse, policy, ordering, or separate lifecycle management; keep
Anthropic request-shape fragments inline when they are versioned payload data
rather than first-class relational concepts.
