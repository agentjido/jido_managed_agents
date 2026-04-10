# Platform Stories

### ST-PLAT-001 Define The Ash Platform Architecture

#### User Story

As the maintainer of the OSS example,
I want an explicit Ash architecture for domains, resource boundaries, relationships, and Postgres conventions,
so that the rest of the system is built on a clear and durable foundation before feature work begins.

#### Traceability

- RQ-003 Ash Domain Foundation
- RQ-002 Multi-User Ownership And Auth

#### Dependencies

- None.

#### Acceptance Criteria

- Define domain modules for Accounts, Agents, Sessions, and Integrations.
- Document which resources belong to each domain and how cross-domain references are handled.
- Standardize ownership rules so every mutable managed-agents resource is scoped to a `User`.
- Standardize that persisted managed-agents resources use `AshPostgres.DataLayer` and live in Postgres.
- Establish shared conventions for `id`, `metadata`, `inserted_at` or `created_at`, `updated_at`, `archived_at`, and `deleted_at`.
- Document which relationship-backed concepts must be normalized as resources or join resources, and which Anthropic-shaped config fragments may remain versioned fields on a parent resource.
- Add developer-facing docs that explain the Ash stack choices and why the model is split this way.

#### Notes

- This story is about architecture and data-foundation choices, not yet full CRUD behavior.

### ST-PLAT-002 Implement Authorization, Actor Propagation, And RBAC

#### User Story

As a platform developer,
I want authorization and actor propagation designed into the platform before resources land,
so that every later API, LiveView, and runtime action inherits one consistent security model.

#### Traceability

- RQ-002 Multi-User Ownership And Auth
- RQ-003A Authorization And RBAC Foundation

#### Dependencies

- `ST-PLAT-001`

#### Acceptance Criteria

- Add or standardize a simple v1 role model on the authenticated user actor:
  - `member`
  - `platform_admin`
- Standardize that managed-agents resources use `Ash.Policy.Authorizer` for authorization.
- Define shared Ash policy patterns for owner-scoped access and admin override access.
- Ensure browser auth, API key auth, LiveViews, and runtime entry points all resolve and pass an Ash actor consistently through Ash actions.
- Prefer `Ash.Policy.Authorizer` and Ash policies over controller-level authorization branches.
- Reuse the existing `AshAuthentication` and `AshAuthenticationPhoenix` setup rather than adding parallel auth plumbing.
- Add focused tests covering owner access, cross-user denial, admin override, and API-key-backed access.
- Document how API keys inherit the permissions of their owning user.

#### Notes

- Keep RBAC intentionally small in v1. Ownership plus admin override is sufficient.

### ST-PLAT-003 Implement The Agent-Side Catalog Resources

#### User Story

As a platform developer,
I want the agent-side managed-agents resources persisted in Ash,
so that APIs, runtime, and UI all share one canonical configuration model.

#### Traceability

- RQ-003 Ash Domain Foundation
- RQ-003A Authorization And RBAC Foundation
- RQ-002 Multi-User Ownership And Auth

#### Dependencies

- `ST-PLAT-001`
- `ST-PLAT-002`

#### Acceptance Criteria

- Implement Ash resources and migrations for:
  - `Agent`
  - `AgentVersion`
  - `Environment`
  - `Skill`
  - `SkillVersion`
  - relationship resources needed for normalized catalog links such as `AgentVersionSkill` and `AgentVersionCallableAgent`
- Real relationships are normalized in Postgres; Anthropic-shaped config fragments like `tools`, `mcp_servers`, and model specs may remain versioned attributes where that preserves compatibility cleanly.
- Relationships, identities, actions, and policies are explicit and Ash-native.
- Resource tests cover ownership, relationships, version linkage, and archive behavior where applicable.
- Prefer Ash built-ins for relationships, validations, `manage_relationship`, calculations, policies, and actions instead of custom glue code.

#### Notes

- Keep the persistence model simple, but not shallow.

### ST-PLAT-004 Add Cloak And AshCloak Secret Infrastructure

#### User Story

As a platform developer,
I want the app-level encryption infrastructure set up before secret resources land,
so that encrypted credential attributes have a consistent and testable foundation.

#### Traceability

- RQ-017 Encrypted Secrets At Rest

#### Dependencies

- `ST-PLAT-001`

#### Acceptance Criteria

- Add `cloak` and `ash_cloak` to the application and wire them into runtime configuration.
- Define the project `Cloak` vault module and the key-loading strategy for development, test, and production.
- Document how Ash resources will opt into `AshCloak` encrypted attributes.
- Add tests or focused checks proving encrypted attributes are not serialized back in plaintext.
- Keep the encryption setup generic so multiple credential types can reuse it.

#### Notes

- This story is infrastructure only, not yet the vault and credential resource model.

### ST-PLAT-005 Implement Vault Foundation Resources

#### User Story

As a platform developer,
I want vaults modeled in Ash as part of the persisted foundation,
so that sessions and later APIs can reference a first-class secret container.

#### Traceability

- RQ-012 Vaults And Credentials
- RQ-003A Authorization And RBAC Foundation
- RQ-002 Multi-User Ownership And Auth

#### Dependencies

- `ST-PLAT-001`
- `ST-PLAT-002`

#### Acceptance Criteria

- Implement Ash resources and migrations for `Vault`.
- `Vault` ownership, identities, actions, and policies are explicit and Ash-native.
- The resource stores non-secret metadata such as name, description, and display metadata without inventing a second secret store.
- Resource tests cover owner isolation, relationships, and normalized references from later `SessionVault` joins.
- Document how `Vault` fits into the overall secret model and session credential resolution flow.

#### Notes

- This story establishes the container model for secrets before credentials and APIs land.

### ST-PLAT-006 Implement Credential Foundation Resources

#### User Story

As a platform developer,
I want credentials modeled in Ash with encrypted and queryable fields separated cleanly,
so that the system can resolve secrets safely without losing efficient matching behavior.

#### Traceability

- RQ-012 Vaults And Credentials
- RQ-017 Encrypted Secrets At Rest
- RQ-003A Authorization And RBAC Foundation
- RQ-002 Multi-User Ownership And Auth

#### Dependencies

- `ST-PLAT-001`
- `ST-PLAT-002`
- `ST-PLAT-004`
- `ST-PLAT-005`

#### Acceptance Criteria

- Implement Ash resources and migrations for `Credential`.
- `Credential` belongs to `Vault` and uses `AshCloak` encrypted attributes backed by the app's `Cloak` vault.
- Queryable routing fields needed for matching and policy, such as `type` and `mcp_server_url`, remain queryable in Postgres while secret-bearing fields remain encrypted.
- Relationships, identities, actions, and policies are explicit and Ash-native.
- Resource tests cover owner isolation, encrypted persistence, and write-only serialization boundaries for secret attributes.
- Document which credential attributes are encrypted, which remain queryable, and why.

#### Notes

- This story establishes the persisted credential model before vault APIs and MCP runtime wiring land.

### ST-PLAT-007 Implement The Session-Side Foundation Resources

#### User Story

As a platform developer,
I want workspaces, sessions, session-vault links, threads, and events modeled explicitly in Ash,
so that runtime, APIs, and UI all share a durable and queryable execution model.

#### Traceability

- RQ-003 Ash Domain Foundation
- RQ-003A Authorization And RBAC Foundation
- RQ-007 Session Resource And Lifecycle
- RQ-007A Workspace As A First-Class Concept

#### Dependencies

- `ST-PLAT-001`
- `ST-PLAT-002`
- `ST-PLAT-005`

#### Acceptance Criteria

- Implement Ash resources and migrations for:
  - `Workspace`
  - `Session`
  - `SessionVault`
  - `SessionThread`
  - `SessionEvent`
- The `Workspace` resource is first-class and not reduced to an opaque string reference.
- Default identities support one workspace per `(user_id, agent_id)` for v1.
- The persisted model enforces that at most one active session in status `idle` or `running` may exist per workspace at a time.
- Relationships are explicit and normalized, especially around session references to agent versions, environments, workspaces, and ordered vault selection.
- `SessionVault` preserves ordered `vault_ids` instead of storing an unordered array.
- `Session` includes explicit soft-delete fields and state so later API delete behavior preserves execution history.
- Resource tests cover ownership, relationships, ordered vault linkage, active-session exclusivity, lifecycle fields, and soft-delete modeling.
- Prefer Ash built-ins for validations, identities, relationships, and policies instead of custom code.

#### Notes

- This is the persisted execution model, not yet the runtime loop.

### ST-PLAT-008 Add The Anthropic-Style `/v1` API Skeleton

#### User Story

As an API client developer,
I want a stable `/v1` surface with Anthropic-style auth and envelopes,
so that local examples feel like the Managed Agents API.

#### Traceability

- RQ-001 Anthropic-Compatible API Surface
- RQ-002 Multi-User Ownership And Auth
- RQ-003A Authorization And RBAC Foundation

#### Dependencies

- `ST-PLAT-002`
- `ST-PLAT-003`
- `ST-PLAT-005`
- `ST-PLAT-006`
- `ST-PLAT-007`

#### Acceptance Criteria

- Add a `/v1` router scope separate from the existing JSON:API router.
- Authenticate API requests with `x-api-key` using the existing Ash API key strategy.
- Ensure controller and action plumbing passes the resolved Ash actor all the way into resource actions.
- The API accepts `anthropic-version` and `anthropic-beta` headers without rejecting compatible requests.
- Add shared serialization helpers for:
  - Anthropic-style list responses shaped like `{"data": [...], "has_more": false}`
  - Anthropic-style error responses shaped like `{"error": {"type": "...", "message": "..."}}`
- Add shared controller tests proving unauthorized access is rejected and cross-user access is blocked.
- Add a short guide explaining when to use `/v1` versus the existing internal JSON:API routes.

#### Notes

- Do not expose JSON:API payloads on `/v1`.
