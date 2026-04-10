# Integration Stories

### ST-VLT-001 Implement Vaults And Credentials With Encrypted Secrets

#### User Story

As a user connecting third-party services,
I want to register per-user vaults and credentials,
so that sessions can act on my behalf without exposing raw secrets.

#### Traceability

- RQ-012 Vaults And Credentials
- RQ-017 Encrypted Secrets At Rest

#### Dependencies

- `ST-PLAT-005`
- `ST-PLAT-006`
- `ST-PLAT-008`

#### Acceptance Criteria

- Expose the persisted `Vault` and `Credential` foundation resources through endpoints close to Anthropic's documented surface:
  - `POST /v1/vaults`
  - `GET /v1/vaults`
  - `GET /v1/vaults/{id}`
  - `DELETE /v1/vaults/{id}`
  - `POST /v1/vaults/{vault_id}/credentials`
  - `GET /v1/vaults/{vault_id}/credentials`
  - `GET /v1/vaults/{vault_id}/credentials/{id}`
  - `PUT /v1/vaults/{vault_id}/credentials/{id}`
  - `DELETE /v1/vaults/{vault_id}/credentials/{id}`
- Support `mcp_oauth` and `static_bearer` credential types.
- Sensitive credential fields are encrypted at rest using `cloak` and `ash_cloak`.
- Secret fields are write-only and are never returned after creation or rotation.
- Rotation respects the documented immutability of fields like `mcp_server_url`, `token_endpoint`, and `client_id`.
- Tests cover write-only serialization, encryption behavior, rotation, delete behavior, and cross-user isolation.

#### Notes

- Anthropic treats vaults as workspace-scoped. This example intentionally scopes them per user.
- Do not re-model secrets outside the Ash foundation resources.

### ST-MCP-001 Integrate `jido_mcp` With Vault-Resolved Auth

#### User Story

As an agent author,
I want MCP servers declared on the agent and credentials supplied per session,
so that reusable agent definitions stay separate from end-user secrets.

#### Traceability

- RQ-013 MCP Connector Via Jido.MCP
- RQ-012 Vaults And Credentials
- RQ-011 Human-In-The-Loop Approval

#### Dependencies

- `ST-VLT-001`
- `ST-TOL-001`
- `ST-SES-004`
- `ST-TOL-005`

#### Acceptance Criteria

- Agent definitions support `mcp_servers` entries with Anthropic-compatible fields: `type`, `name`, and `url`.
- Sessions resolve MCP credentials from referenced vaults by matching `mcp_server_url`.
- Runtime execution uses `jido_mcp`, not a custom MCP transport.
- MCP tool discovery and invocation are wired into the Jido session runtime in a way compatible with agent tool declarations.
- Runtime behavior follows the spec:
  - session creation can succeed even when credentials are invalid
  - auth failures surface as session or tool errors rather than hard crashes
  - when multiple vaults match the same MCP server, first match wins
- MCP tool invocations emit `agent.mcp_tool_use` and `agent.mcp_tool_result`.
- Tests cover successful matching, missing credentials, invalid credentials, and vault precedence.

#### Notes

- Keep the proxy boundary explicit even if the first runtime implementation is modest.

### ST-SKL-001 Implement Skill Registry And Agent Skill Attachment

#### User Story

As an agent author,
I want to attach Anthropic and custom skills to an agent,
so that the runtime can load reusable specialist instructions on demand.

#### Traceability

- RQ-014 Skills

#### Dependencies

- `ST-PLAT-003`
- `ST-AGT-002`

#### Acceptance Criteria

- Agent definitions accept Anthropic and custom skill references using Anthropic-compatible fields: `type`, `skill_id`, and optional `version`.
- Expose the persisted skill registry created in the platform epic for custom skills with version metadata.
- Enforce the documented session limit of 20 total skills across all agents in a session.
- Custom skill records can point to filesystem-backed content such as `SKILL.md`, scripts, and assets.
- The persistence model aligns with Jido AI skill and skill-version concepts rather than inventing unrelated parallel structures.
- Tests cover validation, attachment, missing skills, version resolution, and session-limit enforcement.

#### Notes

- Progressive disclosure can land later, but the registry and contract should be correct now.

### ST-SKL-002 Integrate Skills With The Existing Jido AI Runtime

#### User Story

As a runtime developer,
I want persisted agent skills to plug into Jido AI's existing skill and skill-version capabilities,
so that the app reuses the runtime features already present instead of re-implementing them.

#### Traceability

- RQ-014 Skills
- RQ-009 Provider-Backed Jido Runtime

#### Dependencies

- `ST-SKL-001`
- `ST-SES-004`

#### Acceptance Criteria

- Agent runtime construction passes persisted skill references into the Jido AI runtime using the framework's native skill/version support.
- Skill version resolution is explicit and testable.
- Missing or invalid skills fail clearly at session/runtime boundaries.
- Add tests covering a session with skills attached and a session with invalid skill references.

#### Notes

- Reuse Jido AI skill features instead of writing custom skill execution machinery.
