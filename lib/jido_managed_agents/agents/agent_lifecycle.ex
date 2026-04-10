defmodule JidoManagedAgents.Agents.AgentLifecycle do
  @moduledoc false

  alias JidoManagedAgents.Repo

  @archived_query """
  SELECT archived_at
  FROM agents
  WHERE id = $1
  """

  @delete_blockers_query """
  SELECT
    (
      SELECT COUNT(*)::bigint
      FROM sessions
      WHERE agent_id = $1
    ) AS session_count,
    (
      SELECT COUNT(*)::bigint
      FROM agent_version_callable_agents
      WHERE callable_agent_id = $1
         OR callable_agent_version_id IN (
              SELECT id
              FROM agent_versions
              WHERE agent_id = $1
            )
    ) AS callable_reference_count
  """

  def archived?(agent_id) do
    with {:ok, %{rows: rows}} <- Repo.query(@archived_query, [dump_uuid!(agent_id)]) do
      {:ok, match?([[archived_at]] when not is_nil(archived_at), rows)}
    end
  end

  def delete_blockers(agent_id) do
    with {:ok, %{rows: [[session_count, callable_reference_count]]}} <-
           Repo.query(@delete_blockers_query, [dump_uuid!(agent_id)]) do
      {:ok,
       %{
         session_count: session_count,
         callable_reference_count: callable_reference_count
       }}
    end
  end

  def delete_allowed?(agent_id) do
    with {:ok, blockers} <- delete_blockers(agent_id) do
      {:ok, blockers.session_count == 0 and blockers.callable_reference_count == 0}
    end
  end

  def delete_conflict_message(%{session_count: session_count} = blockers)
      when session_count > 0 do
    if blockers.callable_reference_count > 0 do
      "Cannot delete an agent that has dependent sessions or callable-agent references."
    else
      "Cannot delete an agent that has dependent sessions."
    end
  end

  def delete_conflict_message(%{callable_reference_count: callable_reference_count})
      when callable_reference_count > 0 do
    "Cannot delete an agent that is referenced by callable-agent declarations."
  end

  def delete_conflict_message(_blockers), do: nil

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
