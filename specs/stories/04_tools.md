# Runtime Tool Stories

### ST-TOL-002 Implement Workspace And Filesystem Tools

#### User Story

As a session user,
I want the agent to use the documented filesystem tools inside a managed workspace,
so that the core coding-assistant loop behaves like Anthropic's tool bundle.

#### Traceability

- RQ-010 Tool Configuration And Execution

#### Dependencies

- `ST-SES-003`
- `ST-TOL-001`
- `ST-WKS-002`

#### Acceptance Criteria

- Implement runtime execution for:
  - `read`
  - `write`
  - `edit`
  - `glob`
  - `grep`
- Tool invocation emits `agent.tool_use` before execution and `agent.tool_result` after execution.
- Tool inputs and outputs are persisted in the event log.
- Runtime execution uses a session workspace abstraction that can later support thread sharing.
- Tool failures are surfaced as structured results or `session.error` events rather than crashing the runtime.
- Tests cover successful execution, failure cases, and event emission order.

#### Notes

- Keep the workspace contract explicit because later thread support depends on it.

### ST-TOL-003 Implement `bash` Tool Execution

#### User Story

As a session user,
I want the agent to run shell commands through the documented `bash` tool,
so that the example supports real coding workflows.

#### Traceability

- RQ-010 Tool Configuration And Execution

#### Dependencies

- `ST-TOL-002`

#### Acceptance Criteria

- Implement `bash` execution with bounded timeout, captured stdout or stderr, and explicit exit status.
- `bash` calls emit the same Anthropic-style tool-use and tool-result events as other built-in tools.
- Runtime policy around command execution is explicit and testable.
- Tests cover success, command failure, timeout, and workspace isolation behavior.

#### Notes

- Keep execution policy visible in code. Do not bury critical limits in defaults.

### ST-TOL-004 Implement `web_fetch` And `web_search`

#### User Story

As a session user,
I want the agent to fetch and search the web using the documented built-in tool names,
so that the OSS example stays close to Anthropic's published tool bundle.

#### Traceability

- RQ-010 Tool Configuration And Execution

#### Dependencies

- `ST-TOL-002`

#### Acceptance Criteria

- Implement `web_fetch` using `Req` and return normalized text or metadata suitable for model consumption.
- Implement `web_search` using a configurable adapter with a sane OSS default and compact normalized result sets.
- Both tools emit Anthropic-style tool events through the same event log.
- Tool configuration can disable either tool through the built-in toolset config model.
- Tests cover success, network failures, disabled-tool behavior, and deterministic adapter stubbing.

#### Notes

- Use `Req` for outbound HTTP and keep adapters swappable.

### ST-TOL-005 Add Approval And `requires_action` Flow

#### User Story

As a cautious session user,
I want risky tools to pause for confirmation,
so that human approval gates execution when policy requires it.

#### Traceability

- RQ-011 Human-In-The-Loop Approval
- RQ-008 Session Events And SSE

#### Dependencies

- `ST-TOL-003`
- `ST-SES-005`

#### Acceptance Criteria

- When a tool with `always_ask` is about to run, the session emits the relevant tool-use event and then transitions to `session.status_idle` with `stop_reason.type = "requires_action"`.
- `POST /v1/sessions/{id}/events` accepts `user.tool_confirmation` events with `tool_use_id` and `result = "allow" | "deny"`.
- Allowed confirmations resume the session and continue execution.
- Denied confirmations produce a clear result event or error event visible to the user.
- Tests cover allow, deny, invalid tool IDs, and repeated confirmations.

#### Notes

- This is the core human-in-the-loop primitive and should remain explicit in the event log.

### ST-TOL-006 Implement Custom Tool Round-Trips

#### User Story

As an application integrator,
I want the agent to request custom tools and wait for my app to supply results,
so that external business logic can participate in the session loop.

#### Traceability

- RQ-010 Tool Configuration And Execution
- RQ-011 Human-In-The-Loop Approval

#### Dependencies

- `ST-TOL-005`

#### Acceptance Criteria

- Custom tool invocation emits `agent.custom_tool_use` with the tool name and structured input.
- The session transitions to `idle` with `stop_reason.type = "requires_action"` and references the blocking event IDs.
- `user.custom_tool_result` unblocks the session when the referenced event ID is valid and unresolved.
- Once all blocking custom tool results are received, the session resumes and emits `session.status_running`.
- Tests cover single and multiple blocking custom tool calls, invalid result IDs, and duplicate result handling.

#### Notes

- Keep this implementation generic so application-specific tools do not need core changes.
