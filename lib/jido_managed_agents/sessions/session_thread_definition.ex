defmodule JidoManagedAgents.Sessions.SessionThreadDefinition do
  @moduledoc """
  Serialization helpers for public session thread API responses.
  """

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions.SessionThread

  @spec serialize_thread(SessionThread.t()) :: map()
  def serialize_thread(%SessionThread{} = thread) do
    %{
      id: thread.id,
      type: "session_thread",
      session_id: thread.session_id,
      parent_thread_id: thread.parent_thread_id,
      role: to_string(thread.role),
      status: to_string(thread.status),
      stop_reason: thread.stop_reason,
      agent: serialize_agent_reference(thread),
      created_at: thread.created_at,
      updated_at: thread.updated_at
    }
  end

  defp serialize_agent_reference(%SessionThread{
         agent_id: agent_id,
         agent_version: %AgentVersion{} = version
       }) do
    %{type: "agent", id: agent_id, version: version.version}
  end

  defp serialize_agent_reference(%SessionThread{agent_id: agent_id}) do
    %{type: "agent", id: agent_id, version: nil}
  end
end
