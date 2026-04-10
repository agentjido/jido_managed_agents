# Agent And Declaration Stories

### ST-AGT-001 Implement Agent CRUD With Anthropic-Compatible Shapes

#### User Story

As an API user,
I want to create, retrieve, and list agent definitions using Anthropic-style payloads,
so that I can configure reusable agents without learning a custom schema.

#### Traceability

- RQ-005 Agent Resource And Versioning

#### Dependencies

- `ST-PLAT-003`
- `ST-PLAT-008`

#### Acceptance Criteria

- Implement `POST /v1/agents`, `GET /v1/agents`, and `GET /v1/agents/{id}`.
- The create request accepts Anthropic field names: `name`, `model`, `system`, `tools`, `mcp_servers`, `skills`, `callable_agents`, `description`, and `metadata`.
- `model` accepts:
  - an Anthropic-compatible string
  - an Anthropic-compatible object with `id` and `speed`
  - a ReqLLM provider-qualified string such as `provider:model`
  - a ReqLLM inline map with `provider` and `id`
- Responses serialize the latest version in an Anthropic-like shape including `type`, `version`, `created_at`, `updated_at`, and `archived_at`.
- List results are newest first and exclude archived records by default.
- API tests cover creation, retrieval, listing, and user isolation.

#### Notes

- Creating an agent should create its initial version record automatically.

### ST-AGT-002 Add Agent Versioning And Update Semantics

#### User Story

As an API user,
I want agent updates to create immutable versions with Anthropic-like semantics,
so that I can roll forward safely and pin sessions to known versions.

#### Traceability

- RQ-005 Agent Resource And Versioning

#### Dependencies

- `ST-AGT-001`

#### Acceptance Criteria

- Implement `PUT /v1/agents/{id}`, `GET /v1/agents/{id}/versions`, `POST /v1/agents/{id}/archive`, and `DELETE /v1/agents/{id}`.
- `PUT` requires a current `version` and creates a new immutable version unless the change is a no-op.
- Update semantics follow the spec:
  - omitted scalar fields are preserved
  - provided scalar fields replace prior values
  - array fields replace the previous array entirely
  - `metadata` merges by key and empty-string values delete keys
- Archived agents become read-only and cannot be used for new sessions.
- Delete behavior is explicit and safe when dependent sessions exist.
- Tests cover version increments, metadata merge behavior, no-op detection, archive behavior, and delete constraints.

#### Notes

- Keep version records explicit rather than reconstructing them later.

### ST-TOL-001 Model Tool Declarations And Permission Policies

#### User Story

As an agent author,
I want to declare built-in, MCP, and custom tools using Anthropic-compatible shapes,
so that an agent version fully describes what it is allowed to do.

#### Traceability

- RQ-010 Tool Configuration And Execution
- RQ-011 Human-In-The-Loop Approval

#### Dependencies

- `ST-AGT-002`

#### Acceptance Criteria

- Agent versions support these tool entry types:
  - `{type: "agent_toolset_20260401"}`
  - `{type: "mcp_toolset", mcp_server_name: "..."}`
  - `{type: "custom", name: "...", description: "...", input_schema: {...}}`
- Built-in toolset configs support Anthropic-style `default_config` and per-tool `configs`.
- Permission policies support at least `always_allow` and `always_ask`.
- Tool declarations are validated and stored in a form the runtime can consume directly.
- Tests cover valid and invalid tool declarations plus permission-policy defaults.

#### Notes

- Keep the canonical bundle name `agent_toolset_20260401` even though execution is local.

### ST-AGT-003 Import And Export Anthropic Agent YAML

#### User Story

As a repository-driven user,
I want Anthropic-style agent YAML to work directly in this platform,
so that I can version-control agent definitions and sync them with the app.

#### Traceability

- RQ-004 Agent YAML Compatibility
- RQ-016 Console-Like Dashboard

#### Dependencies

- `ST-AGT-002`
- `ST-TOL-001`

#### Acceptance Criteria

- Support importing an agent definition from a YAML document shaped like the Anthropic create-agent body.
- Support exporting the latest or a pinned agent version to YAML.
- The recommended filename convention is `*.agent.yaml`.
- YAML parsing preserves nested structures for tools, MCP servers, skills, metadata, callable agents, and model objects.
- Tool declarations round-trip through the same validation and serialization model used by the API.
- Add contract tests that round-trip Anthropic-style fixture YAML through import, persistence, and export without shape drift.
- Anthropic-compatible YAML continues to work unchanged even though the platform also accepts ReqLLM-native model forms as a local extension.
- Expose serialization helpers that the later dashboard story can reuse for API and YAML previews.

#### Notes

- Anthropic documents the YAML shape through the same agent payload, not through a separate formal schema file.
