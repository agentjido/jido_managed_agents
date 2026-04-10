# Managed Agents OSS Example Specification

## Goal

Build an open source example implementation of Anthropic Managed Agents using Elixir, Phoenix, Ash, Jido, `jido_mcp`, and `req_llm`.

The project should stay as close as practical to Anthropic's published Managed Agents product as documented on April 9, 2026, especially for:

- REST paths and resource names
- JSON request and response shapes
- The Anthropic-style agent YAML definition
- Session, event, thread, and approval semantics
- The general structure of the Anthropic dashboard and tracing experience

This implementation is intentionally multi-user from day one and should be published as a small but real OSS example, not a fake mock.

## Product Principles

- External compatibility first. Match Anthropic's public contract before adding local inventions.
- Ash first. The foundation is a clear domain model with persisted resources, relationships, and policies.
- Use the Ash stack. Prefer `Ash`, `AshPostgres`, `AshAuthentication`, `AshAuthenticationPhoenix`, `AshPhoenix`, and `Ash.Policy.Authorizer` before custom infrastructure.
- Prefer the framework. Use Ash relationships, policies, validations, actions, identities, and serializers before writing custom infrastructure.
- Real runtime. Sessions use a real provider-backed Jido loop, not Claude Code and not another external agent harness.
- Provider flexible. Anthropic compatibility does not imply Anthropic-only inference. Runtime inference should be mediated through `req_llm`.
- Secure by default. Credentials are stored in Postgres and encrypted at rest with `cloak` and `ash_cloak`.
- Honest divergence. Do not claim local Jido workers are Anthropic's hosted cloud runtime.
- OSS friendly. The repository should teach the architecture clearly through code, examples, and docs.

## Compatibility Contract

### HTTP API

- Public API routes live under `/v1`.
- Resource names and nested paths mirror Anthropic Managed Agents wherever feasible.
- Request and response field names preserve Anthropic naming such as `environment_id`, `vault_ids`, `callable_agents`, `stop_reason`, and `session_thread_id`.
- Responses use Anthropic-style JSON payloads rather than JSON:API envelopes.
- API requests authenticate with `x-api-key`, backed by the existing Ash API key strategy.
- The API should accept `anthropic-version` and `anthropic-beta` headers for compatibility, but local semantics are controlled by this app.

### Agent YAML

- Agent definitions are imported from and exported to `*.agent.yaml`.
- The YAML shape matches the Anthropic agent create or update body.
- Anthropic-compatible YAML examples from the gathered docs should round-trip through import, persistence, and export without shape drift.
- The YAML contract is a first-class compatibility target, not just a UI convenience.

### Dashboard Shape

The browser UI should follow the Anthropic Console structure closely:

- An agent builder with model, system prompt, tools, MCP servers, skills, and callable agents
- A preview of the equivalent API request and YAML definition
- An inline session runner for testing an agent without leaving the page
- Environment and vault management views
- A session list and trace view with timeline, raw events, and tool activity

## Intentional v1 Divergences

- Anthropic resources are workspace-scoped. In this OSS example, mutable resources are user-scoped for straightforward multi-user isolation.
- Anthropic provisions hosted cloud containers. In v1, environments are local-runtime templates executed by supervised Jido processes.
- Anthropic has adjacent features not captured in the gathered docs, such as memory stores and GitHub-specific session resources. Those are deferred.
- Anthropic Console has organization-role concepts. In v1, authorization is simplified to owner-scoped resources plus a small Ash-native role model for `member` and `platform_admin`.

## Ash Domain Model

The foundation should be explicit Ash domains with clear ownership and boundaries.

### Ash Stack And Persistence

Use the Ash ecosystem directly wherever practical:

- `Ash` for domains, resources, actions, changes, validations, identities, aggregates, calculations, and policies
- `AshPostgres` as the data layer for all persisted managed-agents resources in Postgres
- `AshAuthentication` and `AshAuthenticationPhoenix` for browser auth, API key auth, and actor resolution
- `AshPhoenix` for LiveView forms and resource-backed UI workflows
- `AshJsonApi` may continue to serve internal app flows, but the Anthropic-compatible public surface is the custom `/v1` API

### Accounts Domain

Owned concepts:

- `User`
- `ApiKey`
- `Token`

Responsibilities:

- Browser authentication
- API authentication
- Ownership and actor propagation

### Agents Domain

Owned concepts:

- `Agent`
- `AgentVersion`
- `AgentVersionSkill`
- `AgentVersionCallableAgent`
- `Environment`
- `Skill`
- `SkillVersion`

Responsibilities:

- Versioned reusable configuration
- Anthropic-compatible serialization
- YAML import and export

### Sessions Domain

Owned concepts:

- `Workspace`
- `Session`
- `SessionVault`
- `SessionThread`
- `SessionEvent`
- optional derived read models such as `SessionToolCall` or `PendingAction` when useful for UI and querying

Responsibilities:

- Reusable workspace lifecycle
- Stateful execution lifecycle
- Append-only event log
- Runtime projections
- Thread isolation and aggregation

### Integrations Domain

Owned concepts:

- `Vault`
- `Credential`

Responsibilities:

- Per-user secrets
- MCP credential resolution
- Encrypted-at-rest storage

### Authorization And RBAC

Authorization should be Ash-native and explicit from the beginning.

- Every mutable managed-agents resource uses `Ash.Policy.Authorizer`.
- All browser, API, LiveView, and runtime actions pass an explicit Ash actor.
- API keys inherit the permissions of their owning user rather than introducing a separate tenancy model.
- v1 RBAC is intentionally simple:
  - `member` users manage only their own resources
  - `platform_admin` users can administer resources across users for support, seeding, and OSS-demo operations
- Ownership checks should be expressed with Ash policies and relationship filters instead of controller-level `if current_user.id == ...` logic.
- Role checks should be centralized in policy patterns that can be reused across the Accounts, Agents, Sessions, and Integrations domains.

### Primary Relationships

The initial data foundation should normalize real relationships in Postgres instead of leaving them implicit in blobs:

- `User` has many `ApiKey`, `Agent`, `Environment`, `Workspace`, `Session`, `Vault`, and custom `Skill` records.
- `Agent` belongs to `User` and has many immutable `AgentVersion` records.
- `AgentVersion` belongs to `Agent` and manages Anthropic-shaped config fields such as model, system, tools, MCP servers, and metadata.
- `AgentVersion` relates to reusable skills through a join resource such as `AgentVersionSkill`, with an optional pinned `SkillVersion`.
- `AgentVersion` relates to callable agents through a join resource such as `AgentVersionCallableAgent`, with an optional pinned target version.
- `Skill` belongs to `User` and has many `SkillVersion` records.
- `Environment` belongs to `User`.
- `Workspace` belongs to `User` and `Agent`, and has many `Session` records.
- `Session` belongs to `User`, `Agent`, `AgentVersion`, `Environment`, and `Workspace`, and has many `SessionThread`, `SessionEvent`, and ordered `SessionVault` records.
- `SessionVault` belongs to `Session` and `Vault` and preserves the order of incoming `vault_ids`.
- `SessionThread` belongs to `Session`, the executing `Agent`, the executing `AgentVersion`, and optionally a `parent_thread`.
- `SessionEvent` belongs to `Session` and optionally to `SessionThread`.
- `Vault` belongs to `User` and has many `Credential` records.
- `Credential` belongs to `Vault`.

## Runtime Architecture

### Persistence

Ash resources are the source of truth. Jido processes are execution state, not canonical storage.

Every managed-agents resource should be owned by a `User`, except shared internal projections if later introduced.

### Session Runtime

- Each session is backed by a Jido-native runtime process or instance-manager entry.
- The runtime consumes persisted user events and produces persisted agent or session events.
- The runtime uses `jido_ai` patterns for request handling, tool use, and bounded execution.
- Provider-specific inference is mediated through `req_llm`, keeping the session loop provider-flexible.
- No external agent harnesses should be invoked.
- Streaming granularity follows persisted Jido AI signals and turn events; v1 should not invent a separate token-stream protocol outside that event model.

### Workspace Runtime

- Workspace is a first-class concept even though Anthropic does not expose it as a public top-level resource.
- Workspaces persist across sessions.
- The default workspace reuse identity for v1 is `(user_id, agent_id)`.
- Sessions for a given agent always run inside that agent's workspace.
- At most one active session may exist per workspace at a time.
- v1 supports two workspace backends:
  - `memory_vfs`
  - `local_vfs`
- The initial release does not depend on sprite-backed or cloud-sandbox-backed workspaces, but the abstraction should allow those later.

### MCP Runtime

- MCP connectivity uses `jido_mcp`.
- MCP servers declared on agents are resolved to `jido_mcp` endpoints at runtime.
- MCP tool discovery and proxying should use the `jido_mcp` Jido.AI integration path where practical.

### Security

- Credentials are stored in Postgres.
- Sensitive credential fields are encrypted at rest with `cloak` and `ash_cloak`.
- `Credential` resources should use `AshCloak` encrypted attributes backed by a project `Cloak` vault.
- Secret fields remain write-only in API responses.
- Session runtime should resolve decrypted credentials only when needed for tool execution.

## Resource Model

### Agent

Required fields:

- `name`
- `model`

Optional fields:

- `system`
- `tools`
- `mcp_servers`
- `skills`
- `callable_agents`
- `description`
- `metadata`

Versioning rules:

- Each update produces a new immutable version unless the change is a no-op.
- Sessions can reference either the latest agent version by ID or a pinned `{type, id, version}` object.
- Update semantics follow Anthropic's documented rules: omitted scalars preserved, arrays replaced, metadata merged by key, and empty-string metadata values delete keys.

### Environment

Required fields:

- `name`
- `config`

Supported v1 config:

- `config.type = "cloud"`
- `config.networking.type = "unrestricted" | "restricted"`

The external shape mirrors Anthropic while the local runtime uses it as a template for workspace and execution policy.

### Workspace

Workspace is a first-class internal concept even though Anthropic does not expose it as a top-level public resource.

Required references:

- `user_id`
- `agent_id`

Core fields:

- `name`
- `backend`
- `config`
- `state`
- `last_used_at`

Rules:

- Workspaces persist across sessions.
- The default workspace identity for v1 is the tuple `(user_id, agent_id)`.
- Sessions for a given agent always run inside that agent's workspace.
- A workspace may have at most one active session at a time, where active means `idle` or `running`.
- A session references a workspace directly instead of inventing ad-hoc filesystem state.
- Future sprite-backed or cloud-sandbox-backed workspaces are explicitly planned but out of scope for the initial release.

### Session

The session resource must be modeled in detail as a first-class Ash resource.

Required references:

- `user_id`
- `agent_id`
- `agent_version_id`
- `environment_id`
- `workspace_id`

Core fields:

- `title`
- `status`
- `stop_reason`
- `last_processed_event_index`
- `archived_at`
- `deleted_at`

State machine:

- `idle`
- `running`
- `archived`
- `deleted`

Additional relationships:

- ordered vault selection is persisted through `SessionVault` rows rather than a lossy array field

Selection and delete rules:

- `POST /v1/sessions` resolves or creates the default workspace for `(user_id, agent_id)` and persists its `workspace_id`.
- Public v1 session creation does not expose arbitrary workspace selection.
- If that workspace already has an active session in status `idle` or `running`, creation of a second active session is rejected.
- Any supplied `vault_ids` must belong to the session owner and are persisted in the provided order.
- `DELETE /v1/sessions/{id}` is an explicit soft delete that sets `status = "deleted"` and `deleted_at` while preserving the session, threads, events, and session-vault links for auditability.
- Default session list and read surfaces exclude soft-deleted sessions unless an internal or privileged query explicitly opts in.

### SessionThread

Core fields:

- `session_id`
- `agent_id`
- `agent_version_id`
- `parent_thread_id`
- `role`
- `status`
- `stop_reason`

Rules:

- The primary thread represents the session-level view.
- Delegate threads are isolated by context and event stream.

### SessionEvent

The event log is the orchestration primitive.

Core fields:

- `session_id`
- `session_thread_id`
- `sequence`
- `type`
- `content`
- `payload`
- `processed_at`
- `stop_reason`

Required v1 event types:

- `user.message`
- `user.interrupt`
- `user.custom_tool_result`
- `user.tool_confirmation`
- `agent.message`
- `agent.thinking`
- `agent.tool_use`
- `agent.tool_result`
- `agent.mcp_tool_use`
- `agent.mcp_tool_result`
- `agent.custom_tool_use`
- `session.status_running`
- `session.status_idle`
- `session.error`

Stop reasons:

- `end_turn`
- `requires_action`

### SessionVault

This is the ordered join resource behind Anthropic-style `vault_ids`.

Core fields:

- `session_id`
- `vault_id`
- `position`

Rules:

- The incoming `vault_ids` order is preserved exactly.
- Vault precedence during MCP credential resolution is determined by ascending `position`.
- The join is explicit and queryable in Postgres for auditability and deterministic matching.

### Vault and Credential

Vaults are user-scoped in v1.

Core modeling rules:

- `Vault` belongs to a `User` and stores non-secret metadata such as name, description, and display metadata.
- `Credential` belongs to a `Vault` and stores both queryable routing fields such as `type` and `mcp_server_url` and encrypted secret attributes.
- Secret-bearing credential attributes such as bearer tokens, client secrets, refresh tokens, or other secret payloads are encrypted through `AshCloak` using the app's configured `Cloak` vault.
- Queryable routing fields needed for matching and policy remain unencrypted so MCP resolution and uniqueness rules stay efficient.

Credential types:

- `mcp_oauth`
- `static_bearer`

Rules:

- Secret values are encrypted at rest and never returned after creation.
- Credential matching against MCP servers is URL-based.
- Rotation respects Anthropic's documented immutability constraints for fields like `mcp_server_url`, `token_endpoint`, and `client_id`.

### Skill

Supported types:

- `anthropic`
- `custom`

Custom skills may be backed by filesystem content plus metadata in Postgres.

Jido AI already contains skill and skill-version capabilities. This app should integrate with those runtime capabilities rather than re-implementing separate skill execution semantics.

## Model Resolution

The platform must accept Anthropic-compatible agent models while also allowing provider-flexible runtime execution through `req_llm`.

Accepted model forms:

- Anthropic-compatible string IDs such as `claude-sonnet-4-6`
- Anthropic-compatible objects such as `{id, speed}`
- ReqLLM provider-qualified strings such as `anthropic:claude-haiku-4-5` or `openai:gpt-4o`
- ReqLLM inline model maps with at least `provider` and `id`

Resolution rules:

- Provider-qualified ReqLLM forms are passed through directly to `req_llm`.
- Anthropic-compatible unqualified forms remain valid inputs and are normalized through app configuration before runtime use.
- Anthropic-compatible YAML import must work unchanged.
- Local app-native model extensions are allowed, but Anthropic-compatible import remains the primary compatibility target.

## Tool Model

### Built-In Toolset

Support Anthropic's bundle name:

- `agent_toolset_20260401`

The v1 backlog should implement these tool names:

- `bash`
- `read`
- `write`
- `edit`
- `glob`
- `grep`
- `web_fetch`
- `web_search`

### MCP Toolset

The MCP toolset is declared as:

- `{type: "mcp_toolset", mcp_server_name: "..."}`

Rules:

- MCP servers are declared on the agent.
- Credentials are injected per session through vault resolution.
- Execution uses `jido_mcp`.
- Default permission policy is `always_ask`.

### Custom Tools

Custom tools are declared on the agent and executed by application code.

Rules:

- Tool invocation emits `agent.custom_tool_use`.
- The session transitions to `idle` with `stop_reason.type = "requires_action"`.
- The client responds with `user.custom_tool_result`.
- After all blocking events are satisfied, the session returns to `running`.

## Multi-Agent Design

- Coordinator agents may invoke `callable_agents`.
- Only one level of delegation is supported.
- All threads share one logical workspace.
- Each thread has its own append-only event stream.
- The primary session stream is an aggregated view.

## Dashboard Requirements

### Agent Builder

- Structured editing for model, system prompt, tools, MCP servers, skills, and callable agents
- Live API and YAML preview
- Save, update, archive, and version browsing
- Launch a test session with environment and vault selection

### Environment And Vault Views

- CRUD views for environments
- CRUD and rotation views for vaults and credentials
- Clear indicators that secrets are write-only

### Session Runner And Observability

- Inline session runner on the agent page
- Live streaming output
- Approval prompts for blocked tool calls
- Session list view
- Session detail trace with timeline, raw events, tool details, and thread drill-down after multi-agent support lands

## Deferred From v1

- Memory stores and memory tools
- Git repository mounts and other non-documented session resources
- Full Anthropic cloud container parity
- Sprite-backed or cloud-sandbox-backed workspace implementations
- Organization roles and billing parity

## Requirement Inventory

### RQ-001 Anthropic-Compatible API Surface

Expose a `/v1` REST API with Anthropic-style paths, field names, error envelopes, and paginated list responses.

### RQ-002 Multi-User Ownership And Auth

All mutable resources are scoped to the authenticated user and accessible through browser auth or `x-api-key`.

### RQ-003 Ash Domain Foundation

The system is built on explicit Ash domains and resources for Accounts, Agents, Sessions, and Integrations.

### RQ-003A Authorization And RBAC Foundation

The system uses Ash-native actor propagation, policies, and a simple role model so authorization is enforced consistently across browser, API, and runtime execution.

### RQ-004 Agent YAML Compatibility

Anthropic-style agent YAML can be imported, persisted, and exported without contract drift.

### RQ-005 Agent Resource And Versioning

Agents support Anthropic-compatible fields, immutable versions, archive, delete, retrieve, list, and list versions.

### RQ-006 Environment Resource

Environments are reusable templates with Anthropic-compatible config shape and local-runtime semantics.

### RQ-007 Session Resource And Lifecycle

Sessions and session threads are first-class Ash resources with explicit references, statuses, and lifecycle rules.

### RQ-007A Workspace As A First-Class Concept

Workspaces are explicit persisted resources reused across sessions, scoped per user and agent, limited to one active session at a time, and backed by pluggable workspace implementations.

### RQ-008 Session Events And SSE

Sessions persist append-only events, support event append and listing, and stream updates through SSE.

### RQ-009 Provider-Backed Jido Runtime

Session execution uses a real Jido-native runtime backed by configurable `req_llm` providers.

### RQ-010 Tool Configuration And Execution

Built-in, MCP, and custom tools are declared on the agent and executed through the local runtime with persisted events.

### RQ-011 Human-In-The-Loop Approval

Permission policies and `user.tool_confirmation` pause and resume tool execution.

### RQ-012 Vaults And Credentials

Per-user vaults support write-only credentials, rotation, delete, list, and URL-based MCP matching.

### RQ-013 MCP Connector Via Jido.MCP

MCP server declarations live on the agent while credentials are injected per session and executed via `jido_mcp`.

### RQ-014 Skills

Agents can attach Anthropic and custom skills, with custom skills backed by local files and metadata and integrated with Jido AI skill support.

### RQ-015 Multi-Agent Threads

Coordinator agents can delegate to callable agents with one level of depth and per-thread event streams.

### RQ-016 Console-Like Dashboard

The dashboard includes an agent builder, environment and vault pages, inline session runner, sessions list, and tracing views.

### RQ-017 Encrypted Secrets At Rest

Credential secrets are stored in Postgres encrypted at rest with `cloak` and `ash_cloak`.

### RQ-018 OSS Example Readiness

The repository includes sample YAML files, walkthrough docs, and seed data so others can run the example locally.
