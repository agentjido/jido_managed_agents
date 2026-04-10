# Managed Agents Traceability Matrix

| Story ID | Requirements | Summary | Dependencies |
| --- | --- | --- | --- |
| ST-PLAT-001 | RQ-003, RQ-002 | Define the Ash platform architecture, domain boundaries, relationship strategy, and Postgres conventions. | None |
| ST-PLAT-002 | RQ-003A, RQ-002 | Implement actor propagation, Ash policies, and simple RBAC before feature resources land. | ST-PLAT-001 |
| ST-PLAT-003 | RQ-003, RQ-003A, RQ-002 | Implement the agent-side catalog resources and normalized relationship resources. | ST-PLAT-001, ST-PLAT-002 |
| ST-PLAT-004 | RQ-017 | Add `Cloak` and `AshCloak` secret infrastructure for encrypted Ash attributes. | ST-PLAT-001 |
| ST-PLAT-005 | RQ-012, RQ-003A, RQ-002 | Implement the vault foundation resource as part of the persisted Ash domain model. | ST-PLAT-001, ST-PLAT-002 |
| ST-PLAT-006 | RQ-012, RQ-017, RQ-003A, RQ-002 | Implement the credential foundation resource with encrypted and queryable fields separated cleanly. | ST-PLAT-001, ST-PLAT-002, ST-PLAT-004, ST-PLAT-005 |
| ST-PLAT-007 | RQ-003, RQ-003A, RQ-007, RQ-007A | Implement the session-side foundation resources, per-agent workspace reuse, active-session exclusivity, ordered session-vault links, and soft-delete modeling. | ST-PLAT-001, ST-PLAT-002, ST-PLAT-005 |
| ST-PLAT-008 | RQ-001, RQ-002, RQ-003A | Add `/v1` routing, Anthropic-style auth, error envelopes, and actor-aware controller plumbing. | ST-PLAT-002, ST-PLAT-003, ST-PLAT-005, ST-PLAT-006, ST-PLAT-007 |
| ST-AGT-001 | RQ-005 | Implement agent CRUD request and response shapes with user scoping. | ST-PLAT-003, ST-PLAT-008 |
| ST-AGT-002 | RQ-005 | Add immutable agent versions, update semantics, archive, delete, and list versions. | ST-AGT-001 |
| ST-TOL-001 | RQ-010, RQ-011 | Model built-in, MCP, and custom tool declarations on agent versions, including permission policies. | ST-AGT-002 |
| ST-AGT-003 | RQ-004, RQ-016 | Import and export Anthropic-compatible `*.agent.yaml` definitions and contract-test the shape. | ST-AGT-002, ST-TOL-001 |
| ST-ENV-001 | RQ-006 | Implement environment CRUD using Anthropic-compatible config shape and local-runtime semantics. | ST-PLAT-003, ST-PLAT-008 |
| ST-WKS-001 | RQ-007A, RQ-007 | Implement workspace resolution and active-session rules on top of the persisted workspace model. | ST-PLAT-007, ST-AGT-002 |
| ST-WKS-002 | RQ-007A, RQ-009 | Implement v1 workspace backends for `memory_vfs` and `local_vfs` and attach them to runtime sessions. | ST-WKS-001 |
| ST-SES-001 | RQ-007 | Implement session lifecycle APIs and pinned-version session creation on top of the persisted model. | ST-AGT-002, ST-ENV-001, ST-WKS-001, ST-PLAT-005, ST-PLAT-008 |
| ST-SES-002 | RQ-008, RQ-007 | Persist append-only session events and state transitions. | ST-SES-001 |
| ST-SES-003 | RQ-009, RQ-008 | Build the Jido session runtime skeleton that consumes persisted events, persists Jido signals, and manages state transitions. | ST-SES-002, ST-TOL-001, ST-WKS-002 |
| ST-SES-004 | RQ-009 | Integrate provider-backed inference through `jido_ai` and `req_llm`, including model normalization and failure handling. | ST-SES-003 |
| ST-SES-005 | RQ-008, RQ-016 | Stream persisted session events over SSE for API clients and LiveView consumers. | ST-SES-004 |
| ST-TOL-002 | RQ-010 | Implement workspace and filesystem tools: `read`, `write`, `edit`, `glob`, and `grep`. | ST-SES-003, ST-TOL-001, ST-WKS-002 |
| ST-TOL-003 | RQ-010 | Implement `bash` tool execution with bounded policy and event emission. | ST-TOL-002 |
| ST-TOL-004 | RQ-010 | Implement `web_fetch` and `web_search` with `Req` and deterministic adapters. | ST-TOL-002 |
| ST-TOL-005 | RQ-011, RQ-008 | Implement permission-policy pauses and `user.tool_confirmation` resume flow. | ST-TOL-003, ST-SES-005 |
| ST-TOL-006 | RQ-010, RQ-011 | Implement custom tool request, blocking `requires_action`, and result round-trip. | ST-TOL-005 |
| ST-VLT-001 | RQ-012, RQ-017 | Expose vault and credential CRUD, rotation, and write-only serialization on top of the encrypted foundation resources. | ST-PLAT-005, ST-PLAT-006, ST-PLAT-008 |
| ST-MCP-001 | RQ-013, RQ-012, RQ-011 | Integrate `jido_mcp` with agent MCP declarations, vault-resolved auth, and approval flow. | ST-VLT-001, ST-TOL-001, ST-SES-004, ST-TOL-005 |
| ST-SKL-001 | RQ-014 | Implement skill registry and agent skill attachment for Anthropic and custom skill types. | ST-PLAT-003, ST-AGT-002 |
| ST-SKL-002 | RQ-014, RQ-009 | Integrate persisted skills and skill versions with the existing Jido AI skill runtime. | ST-SKL-001, ST-SES-004 |
| ST-MAG-001 | RQ-015 | Add callable agents, thread persistence, thread APIs, and one-level delegation. | ST-SES-004, ST-AGT-002, ST-TOL-005 |
| ST-UI-001 | RQ-016, RQ-004 | Build a Console-like agent builder with YAML/API preview and an inline session runner. | ST-AGT-003, ST-ENV-001, ST-SES-005, ST-TOL-005, ST-SKL-001, ST-VLT-001 |
| ST-UI-002 | RQ-016, RQ-012 | Build dashboard pages for environments, vaults, credentials, and credential rotation. | ST-ENV-001, ST-VLT-001 |
| ST-UI-003 | RQ-016, RQ-011, RQ-015 | Build session observability views for timeline, raw events, tool executions, and thread drill-down. | ST-UI-001, ST-MAG-001, ST-SES-005 |
| ST-OSS-001 | RQ-018 | Add sample YAMLs, demo data, README quickstart, and end-to-end walkthroughs for the OSS example. | ST-UI-001, ST-UI-002, ST-MCP-001 |
