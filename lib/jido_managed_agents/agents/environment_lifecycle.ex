defmodule JidoManagedAgents.Agents.EnvironmentLifecycle do
  @moduledoc false

  alias JidoManagedAgents.Repo

  @archived_query """
  SELECT archived_at
  FROM environments
  WHERE id = $1
  """

  @delete_blockers_query """
  SELECT COUNT(*)::bigint
  FROM sessions
  WHERE environment_id = $1
  """

  def archived?(environment_id) do
    with {:ok, %{rows: rows}} <- Repo.query(@archived_query, [dump_uuid!(environment_id)]) do
      {:ok, match?([[archived_at]] when not is_nil(archived_at), rows)}
    end
  end

  def delete_blockers(environment_id) do
    with {:ok, %{rows: [[session_count]]}} <-
           Repo.query(@delete_blockers_query, [dump_uuid!(environment_id)]) do
      {:ok, %{session_count: session_count}}
    end
  end

  def delete_allowed?(environment_id) do
    with {:ok, blockers} <- delete_blockers(environment_id) do
      {:ok, blockers.session_count == 0}
    end
  end

  def delete_conflict_message(%{session_count: session_count}) when session_count > 0 do
    "Cannot delete an environment that has dependent sessions."
  end

  def delete_conflict_message(_blockers), do: nil

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
