defmodule JidoManagedAgents.Sessions.SessionEventType do
  @moduledoc """
  Persisted event types supported by the v1 execution model.
  """

  use Ash.Type.Enum,
    values: [
      "user.message",
      "user.interrupt",
      "user.custom_tool_result",
      "user.tool_confirmation",
      "agent.message",
      "agent.thinking",
      "agent.tool_use",
      "agent.tool_result",
      "agent.mcp_tool_use",
      "agent.mcp_tool_result",
      "agent.custom_tool_use",
      "agent.thread_message_sent",
      "agent.thread_message_received",
      "session.status_running",
      "session.status_idle",
      "session.thread_created",
      "session.thread_idle",
      "session.error"
    ]
end
