# Console And OSS Stories

### ST-MAG-001 Add Callable Agents And Session Threads

#### User Story

As a power user,
I want one agent to delegate to other agents inside the same session,
so that specialized subagents can work in parallel with isolated context.

#### Traceability

- RQ-015 Multi-Agent Threads

#### Dependencies

- `ST-SES-004`
- `ST-AGT-002`
- `ST-TOL-005`

#### Acceptance Criteria

- Agent definitions support `callable_agents` entries that reference existing agents and optional pinned versions.
- The runtime supports one level of delegation only.
- Each called agent gets a persisted session thread with its own event stream.
- Implement:
  - `GET /v1/sessions/{id}/threads`
  - `GET /v1/sessions/{id}/threads/{thread_id}/events`
  - `GET /v1/sessions/{id}/threads/{thread_id}/stream`
- The primary session stream remains an aggregated view while thread endpoints expose detailed traces.
- Tests cover delegation, thread persistence, thread listing, and rejected nested delegation.

#### Notes

- All threads share one logical workspace while retaining isolated context and event history.

### ST-UI-001 Build A Console-Like Agent Builder And Session Runner

#### User Story

As a dashboard user,
I want to configure an agent visually and test it from the same page,
so that I can iterate quickly before wiring the API into my own app.

#### Traceability

- RQ-016 Console-Like Dashboard
- RQ-004 Agent YAML Compatibility

#### Dependencies

- `ST-AGT-003`
- `ST-ENV-001`
- `ST-SES-005`
- `ST-TOL-005`
- `ST-SKL-001`
- `ST-VLT-001`

#### Acceptance Criteria

- Add an authenticated LiveView page for creating and editing agents.
- The agent builder includes structured sections for model, system prompt, tools, MCP servers, skills, and callable agents.
- The page shows the equivalent API request body and YAML definition for the current draft.
- Users can launch a test session from the agent page by choosing an environment, optional title, and optional vault selection.
- Workspace selection is automatic in v1: the runner always uses the agent workspace and surfaces a clear conflict when that workspace already has an active session.
- The session runner displays streaming output inline without leaving the agent page.
- The LiveView begins with `<Layouts.app flash={@flash} ...>` and follows the existing Phoenix authentication rules.

#### Notes

- Match Anthropic Console's flow, not its branding.

### ST-UI-002 Build Environment And Vault Management Pages

#### User Story

As a dashboard user,
I want first-class pages for environments, vaults, and credentials,
so that I can manage the core resources required to run sessions without using the raw API.

#### Traceability

- RQ-016 Console-Like Dashboard
- RQ-012 Vaults And Credentials

#### Dependencies

- `ST-ENV-001`
- `ST-VLT-001`

#### Acceptance Criteria

- Add authenticated LiveView pages for listing and editing environments.
- Add authenticated LiveView pages for listing vaults, creating credentials, and rotating credentials.
- The UI makes write-only behavior explicit for secret fields.
- Resource pages use the existing app layout and authentication rules.
- Tests cover rendering, form submission, and user isolation.

#### Notes

- Keep the UX close to Anthropic's resource-management flow while staying visually consistent with this app.

### ST-UI-003 Build Session Observability Views

#### User Story

As a dashboard user,
I want to inspect timelines, raw events, tool executions, and thread traces,
so that I can debug what happened in a session without dropping to the database.

#### Traceability

- RQ-016 Console-Like Dashboard
- RQ-011 Human-In-The-Loop Approval
- RQ-015 Multi-Agent Threads

#### Dependencies

- `ST-UI-001`
- `ST-MAG-001`
- `ST-SES-005`

#### Acceptance Criteria

- Add a session list page showing status, creation time, model, and agent name.
- Add a session detail page with:
  - a chronological timeline of events
  - a raw event view
  - a tool execution view with inputs and results
  - approval controls when the session is waiting on `user.tool_confirmation`
- When multi-agent support is enabled, users can drill into thread-specific traces from the session detail page.
- Token usage or other provider metrics are displayed when available, but the page still works when metrics are absent.
- Tests cover rendering for normal sessions, errored sessions, approval-needed sessions, and threaded sessions.

#### Notes

- Follow Anthropic's observability shape: list, trace, raw events, and tool execution.

### ST-OSS-001 Polish The Repository As An OSS Example

#### User Story

As an external developer,
I want a runnable example with sample resources and a clear walkthrough,
so that I can clone the repo and understand the full system quickly.

#### Traceability

- RQ-018 OSS Example Readiness

#### Dependencies

- `ST-UI-001`
- `ST-UI-002`
- `ST-MCP-001`

#### Acceptance Criteria

- Add example `*.agent.yaml` files and any documented environment examples under a clear examples directory.
- Update `README.md` with a quickstart for:
  - creating a user or API key
  - creating an agent and environment
  - starting a session
  - streaming events
  - configuring a vault and MCP credential
  - using the dashboard
- Provide seed or demo data that makes the dashboard useful on a fresh local setup.
- Document the key compatibility goals and intentional divergences from Anthropic's hosted product.
- Add at least one end-to-end happy-path test or scripted walkthrough validating the example remains functional.

#### Notes

- Keep the example small enough for contributors to understand quickly, but real enough to demonstrate the full flow.
