# Environment, Workspace, And Session Stories

### ST-ENV-001 Implement Environment CRUD With Anthropic-Compatible Config

#### User Story

As an API user,
I want reusable environment templates with Anthropic-style config fields,
so that sessions can reference a stable runtime configuration.

#### Traceability

- RQ-006 Environment Resource

#### Dependencies

- `ST-PLAT-003`
- `ST-PLAT-008`

#### Acceptance Criteria

- Implement `POST /v1/environments`, `GET /v1/environments`, `GET /v1/environments/{id}`, `PUT /v1/environments/{id}`, `POST /v1/environments/{id}/archive`, and `DELETE /v1/environments/{id}`.
- Support the Anthropic-compatible config shape with `config.type = "cloud"` and `config.networking.type = "unrestricted" | "restricted"`.
- Persist environments as reusable templates owned by a user.
- Document clearly that v1 executes locally even though the external shape uses Anthropic's cloud-environment contract.
- Add tests for CRUD, archive, delete, and invalid config values.

#### Notes

- Avoid inventing unsupported Anthropic fields in v1.

### ST-WKS-001 Implement Workspace Resolution And Active-Session Rules

#### User Story

As a platform developer,
I want workspace resolution and locking rules defined on top of the persisted workspace model,
so that sessions consistently reuse the agent workspace and never collide with another active session.

#### Traceability

- RQ-007A Workspace As A First-Class Concept
- RQ-007 Session Resource And Lifecycle

#### Dependencies

- `ST-PLAT-007`
- `ST-AGT-002`

#### Acceptance Criteria

- Workspaces are resolved by default for the `(user_id, agent_id)` tuple.
- Sessions for an agent always bind to that agent workspace and persist `workspace_id` directly.
- The environment remains a session-level choice and is not part of the workspace identity in v1.
- Only one active session with status `idle` or `running` may exist per workspace at a time.
- Tests cover workspace resolution rules, ownership, and active-session exclusivity.

#### Notes

- Workspaces are first-class internally even though they are not Anthropic public API resources.

### ST-WKS-002 Implement V1 Workspace Backends

#### User Story

As a runtime developer,
I want multiple workspace backends behind one interface,
so that the initial release can run without cloud sprites while still planning for richer backends later.

#### Traceability

- RQ-007A Workspace As A First-Class Concept
- RQ-009 Provider-Backed Jido Runtime

#### Dependencies

- `ST-WKS-001`

#### Acceptance Criteria

- Implement a workspace abstraction usable by the runtime and tools.
- Support these v1 backends:
  - `memory_vfs`
  - `local_vfs`
- The initial release does not depend on cloud-sandbox or sprite-backed workspaces.
- The abstraction leaves room for later Jido Shell/Jido VFS or sprite-backed implementations without rewriting the session model.
- Tests cover backend selection, basic lifecycle, and consistent interface behavior.

#### Notes

- This story is about backend abstraction and attachment, not the tool implementations themselves.

### ST-SES-001 Implement Session Lifecycle APIs On The Persisted Model

#### User Story

As an API user,
I want to create and manage sessions against persisted agent, environment, and workspace state,
so that execution starts from a durable, explicit model.

#### Traceability

- RQ-007 Session Resource And Lifecycle

#### Dependencies

- `ST-AGT-002`
- `ST-ENV-001`
- `ST-WKS-001`
- `ST-PLAT-005`
- `ST-PLAT-008`

#### Acceptance Criteria

- Implement `POST /v1/sessions`, `GET /v1/sessions`, `GET /v1/sessions/{id}`, `POST /v1/sessions/{id}/archive`, and `DELETE /v1/sessions/{id}`.
- `POST /v1/sessions` accepts either an agent ID string or an `{type, id, version}` object.
- Session creation resolves or creates the default workspace for `(user_id, agent_id)` and persists that `workspace_id`.
- Public v1 session creation does not expose arbitrary workspace selection.
- If the resolved workspace already has an active session in status `idle` or `running`, creation of a second active session is rejected.
- Session creation accepts and persists ordered `vault_ids`, and every supplied vault must belong to the session owner.
- `DELETE /v1/sessions/{id}` is an explicit soft delete that sets `status = "deleted"` and `deleted_at` while preserving events, threads, and vault links.
- Default session list and standard read behavior exclude soft-deleted sessions unless explicitly requested by internal or privileged flows.
- Tests cover latest-version resolution, pinned-version resolution, session ownership, workspace auto-selection, active-session conflict handling, vault linkage, cross-user vault rejection, soft delete behavior, and lifecycle constraints.

#### Notes

- This story is the API lifecycle on top of the persisted model, not yet the runtime loop.

### ST-SES-002 Persist Append-Only Session Events And State Transitions

#### User Story

As an API user,
I want session work to be driven by a durable append-only event log,
so that runtime execution is auditable and resumable.

#### Traceability

- RQ-008 Session Events And SSE
- RQ-007 Session Resource And Lifecycle

#### Dependencies

- `ST-SES-001`

#### Acceptance Criteria

- Implement `POST /v1/sessions/{id}/events` and `GET /v1/sessions/{id}/events`.
- Persist every event with `session_id`, optional `session_thread_id`, sequence ordering, type, payload, content, processed timestamps, and optional stop-reason data.
- Accept at least these user event types:
  - `user.message`
  - `user.interrupt`
  - `user.custom_tool_result`
  - `user.tool_confirmation`
- Session status transitions are recorded as events rather than hidden process state.
- List responses are paginated and ordered chronologically.
- Tests cover multi-event appends, invalid event types, user scoping, and immutable history.

#### Notes

- This story defines the canonical event schema for runtime, SSE, and UI.

### ST-SES-003 Build The Jido Session Runtime Skeleton

#### User Story

As a runtime developer,
I want a Jido-native session runtime that consumes persisted events and persists Jido signals,
so that execution semantics are durable and observable before provider inference is layered in.

#### Traceability

- RQ-009 Provider-Backed Jido Runtime
- RQ-008 Session Events And SSE

#### Dependencies

- `ST-SES-002`
- `ST-TOL-001`
- `ST-WKS-002`

#### Acceptance Criteria

- Create a Jido-native runtime that consumes persisted session events and produces persisted agent or session events.
- Persist Jido signal-driven turn activity into the `SessionEvent` model used by APIs and UI.
- Runtime state transitions between `idle` and `running` are explicit and durable.
- Workspace attachment is resolved through the first-class workspace abstraction rather than ad-hoc filesystem state.
- Add focused runtime tests covering a simple user-message turn and state transitions between `idle` and `running`.

#### Notes

- Do not shell out to Claude Code or any external agent runtime.

### ST-SES-004 Integrate Provider-Backed Inference Through `jido_ai` And `req_llm`

#### User Story

As a product developer,
I want the Jido runtime to use real provider-backed inference,
so that the OSS example behaves like an actual managed-agent system instead of a mock.

#### Traceability

- RQ-009 Provider-Backed Jido Runtime

#### Dependencies

- `ST-SES-003`

#### Acceptance Criteria

- Integrate `jido_ai` request handling into the session runtime rather than building a custom inference loop.
- Runtime inference is provider-flexible and mediated through `req_llm`.
- Model normalization supports both Anthropic-compatible model forms and ReqLLM-native model specs.
- Model/provider defaults are explicit rather than hidden in prompts or ad-hoc code.
- Runtime failures from providers, transport, validation, or timeouts are surfaced as persisted `session.error` events rather than crashing silently.
- Add focused runtime tests covering a simple provider-backed user-message turn and provider failure behavior.

#### Notes

- Streaming granularity should follow persisted Jido event/signals rather than a custom parallel transport.

### ST-SES-005 Stream Session Events Over SSE

#### User Story

As an API and dashboard user,
I want a live event stream for a session,
so that I can watch agent work unfold in real time.

#### Traceability

- RQ-008 Session Events And SSE
- RQ-016 Console-Like Dashboard

#### Dependencies

- `ST-SES-004`

#### Acceptance Criteria

- Implement `GET /v1/sessions/{id}/stream` as a Server-Sent Events endpoint.
- SSE payloads emit Anthropic-style `data:` lines with JSON event objects.
- The stream can replay persisted events and continue with live broadcasts.
- Session state changes to `running` and back to `idle` are visible in the stream.
- Add tests for authenticated access, replay behavior, live delivery, and closed-session behavior.
- Expose a small subscription interface usable by later LiveViews.

#### Notes

- Keep the transport simple and robust. SSE is the primary delivery mechanism in the spec.
