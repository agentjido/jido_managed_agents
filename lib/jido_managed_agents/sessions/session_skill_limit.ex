defmodule JidoManagedAgents.Sessions.SessionSkillLimit do
  @moduledoc false

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentVersion

  @max_total_skills 20
  @version_load [
    :agent_version_skills,
    agent_version_callable_agents: [:callable_agent, :callable_agent_version]
  ]

  @spec validate(String.t() | nil, struct() | nil) ::
          :ok | {:error, {:invalid_request, String.t()}}
  def validate(nil, _actor), do: :ok

  def validate(agent_version_id, actor) when is_binary(agent_version_id) do
    with {:ok, %AgentVersion{} = agent_version} <-
           load_agent_version_graph(agent_version_id, actor),
         {:ok, {total_skills, _visited}} <- count_total_skills(agent_version, actor, MapSet.new()) do
      if total_skills <= @max_total_skills do
        :ok
      else
        {:error,
         {:invalid_request,
          "sessions support at most #{@max_total_skills} total skills across all agents; resolved #{total_skills}."}}
      end
    end
  end

  def validate(_agent_version_id, _actor) do
    {:error, {:invalid_request, "agent_version_id is required."}}
  end

  defp count_total_skills(%AgentVersion{} = version, actor, visited) do
    if MapSet.member?(visited, version.id) do
      {:ok, {0, visited}}
    else
      visited = MapSet.put(visited, version.id)
      skill_count = Enum.count(version.agent_version_skills || [])

      Enum.reduce_while(
        version.agent_version_callable_agents || [],
        {:ok, {skill_count, visited}},
        fn link, {:ok, {total, visited}} ->
          with {:ok, %AgentVersion{} = callable_version} <- resolve_callable_version(link, actor),
               {:ok, {callable_total, visited}} <-
                 count_total_skills(callable_version, actor, visited) do
            {:cont, {:ok, {total + callable_total, visited}}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        end
      )
    end
  end

  defp resolve_callable_version(%{callable_agent_version_id: version_id}, actor)
       when is_binary(version_id) do
    load_agent_version_graph(version_id, actor)
  end

  defp resolve_callable_version(%{callable_agent: %Agent{id: agent_id}}, actor) do
    load_latest_agent_version_graph(agent_id, actor)
  end

  defp resolve_callable_version(%{callable_agent_id: agent_id}, actor) when is_binary(agent_id) do
    load_latest_agent_version_graph(agent_id, actor)
  end

  defp resolve_callable_version(_link, _actor) do
    {:error, {:invalid_request, "callable agent resolution requires a persisted agent version."}}
  end

  defp load_latest_agent_version_graph(agent_id, actor) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: agent_id}, agent_query_opts(actor))
      |> Ash.Query.load(:latest_version)

    case Ash.read_one(query) do
      {:ok, %Agent{latest_version: %AgentVersion{id: version_id}}} ->
        load_agent_version_graph(version_id, actor)

      {:ok, %Agent{latest_version: nil}} ->
        {:error,
         {:invalid_request, "callable agent #{agent_id} does not have an available version."}}

      {:ok, nil} ->
        {:error, {:invalid_request, "callable agent #{agent_id} was not found."}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_agent_version_graph(version_id, actor) do
    query =
      AgentVersion
      |> Ash.Query.for_read(:by_id, %{id: version_id}, agent_query_opts(actor))
      |> Ash.Query.load(@version_load)

    case Ash.read_one(query) do
      {:ok, %AgentVersion{} = version} ->
        {:ok, version}

      {:ok, nil} ->
        {:error, {:invalid_request, "agent version #{version_id} was not found."}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp agent_query_opts(nil), do: [domain: Agents, authorize?: false]
  defp agent_query_opts(actor), do: [actor: actor, domain: Agents, authorize?: false]
end
