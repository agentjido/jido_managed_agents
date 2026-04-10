defmodule JidoManagedAgents.Sessions.SessionDefinition do
  @moduledoc """
  Normalization and serialization helpers for the public `/v1/sessions` API.
  """

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.{Agent, AgentVersion, Environment}
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions.Session

  @spec normalize_create_payload(map(), struct()) ::
          {:ok, %{agent: Agent.t(), session: map()}} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params, actor) when is_map(params) do
    params = stringify_top_level_keys(params)

    with :ok <- reject_workspace_selection(params),
         {:ok, {agent, agent_version}} <- resolve_agent_reference(Map.get(params, "agent"), actor),
         {:ok, %Environment{} = environment} <-
           get_record_by_id(Environment, Map.get(params, "environment_id"), actor, Agents,
             field: "environment_id"
           ),
         {:ok, title} <- optional_string(Map.get(params, "title"), "title"),
         {:ok, session_vaults} <- normalize_vault_ids(Map.get(params, "vault_ids"), actor) do
      {:ok,
       %{
         agent: agent,
         session: %{
           user_id: actor.id,
           agent_id: agent.id,
           agent_version_id: agent_version.id,
           environment_id: environment.id,
           title: title,
           session_vaults: session_vaults
         }
       }}
    end
  end

  def normalize_create_payload(_params, _actor) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec serialize_session(Session.t()) :: map()
  def serialize_session(%Session{} = session) do
    %{
      id: session.id,
      type: "session",
      agent: serialize_agent_reference(session),
      environment_id: session.environment_id,
      vault_ids: serialize_vault_ids(session),
      title: session.title,
      status: to_string(session.status),
      stop_reason: session.stop_reason,
      archived_at: session.archived_at,
      created_at: session.created_at,
      updated_at: session.updated_at
    }
  end

  defp reject_workspace_selection(params) do
    if Map.has_key?(params, "workspace_id") do
      {:error, {:invalid_request, "workspace_id is not supported in v1 session creation."}}
    else
      :ok
    end
  end

  defp resolve_agent_reference(value, actor)

  defp resolve_agent_reference(value, actor) when is_binary(value) do
    with {:ok, %Agent{} = agent} <- get_record_by_id(Agent, value, actor, Agents, field: "agent"),
         {:ok, %AgentVersion{} = latest_version} <- latest_agent_version(agent, actor) do
      {:ok, {agent, latest_version}}
    end
  end

  defp resolve_agent_reference(%{} = value, actor) do
    value = stringify_top_level_keys(value)

    with :ok <- require_exact_string(value, "type", "agent", "agent"),
         {:ok, agent_id} <-
           required_string(%{"id" => value["id"]}, "id", prefix: "agent."),
         {:ok, version} <- positive_integer(value["version"], "agent.version"),
         {:ok, %Agent{} = agent} <-
           get_record_by_id(Agent, agent_id, actor, Agents, field: "agent"),
         {:ok, %AgentVersion{} = agent_version} <- get_agent_version(agent.id, version, actor) do
      {:ok, {agent, agent_version}}
    end
  end

  defp resolve_agent_reference(_value, _actor) do
    {:error,
     {:invalid_request,
      "agent must be either an agent ID string or an object with type, id, and version."}}
  end

  defp latest_agent_version(%Agent{} = agent, actor) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: agent.id}, actor: actor, domain: Agents)
      |> Ash.Query.load(:latest_version)

    case Ash.read_one(query) do
      {:ok, %Agent{latest_version: %AgentVersion{} = latest_version}} ->
        {:ok, latest_version}

      {:ok, %Agent{latest_version: nil}} ->
        {:error, {:invalid_request, "agent #{agent.id} does not have an available version."}}

      {:ok, nil} ->
        {:error, {:invalid_request, "agent #{agent.id} was not found."}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_agent_version(agent_id, version, actor) do
    query =
      AgentVersion
      |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
      |> Ash.Query.filter(agent_id == ^agent_id and version == ^version)

    case Ash.read_one(query) do
      {:ok, %AgentVersion{} = agent_version} ->
        {:ok, agent_version}

      {:ok, nil} ->
        {:error, {:invalid_request, "agent.version references an unknown agent version."}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_vault_ids(nil, _actor), do: {:ok, []}

  defp normalize_vault_ids(vault_ids, actor) when is_list(vault_ids) do
    vault_ids
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {vault_id, index}, {:ok, acc} ->
      with {:ok, vault_id} <- vault_id_at_index(vault_id, index),
           {:ok, %Vault{} = vault} <-
             get_record_by_id(Vault, vault_id, actor, Integrations, field: "vault_ids"),
           session_vault <- %{
             user_id: actor.id,
             vault_id: vault.id,
             position: index,
             metadata: %{}
           } do
        {:cont, {:ok, acc ++ [session_vault]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_vault_ids(_vault_ids, _actor) do
    {:error, {:invalid_request, "vault_ids must be an array of vault ID strings."}}
  end

  defp get_record_by_id(resource, id, actor, domain, opts) do
    field = Keyword.fetch!(opts, :field)

    with {:ok, id} <- required_string(%{field => id}, field) do
      query = Ash.Query.for_read(resource, :by_id, %{id: id}, actor: actor, domain: domain)

      case Ash.read_one(query) do
        {:ok, nil} ->
          {:error,
           {:invalid_request, "#{Ash.Resource.Info.short_name(resource)} #{id} was not found."}}

        {:ok, record} ->
          {:ok, record}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp serialize_agent_reference(%Session{
         agent_id: agent_id,
         agent_version: %AgentVersion{} = version
       }) do
    %{type: "agent", id: agent_id, version: version.version}
  end

  defp serialize_agent_reference(%Session{agent_id: agent_id}) do
    %{type: "agent", id: agent_id, version: nil}
  end

  defp serialize_vault_ids(%Session{session_vaults: session_vaults})
       when is_list(session_vaults) do
    Enum.map(session_vaults, & &1.vault_id)
  end

  defp serialize_vault_ids(%Session{}), do: []

  defp require_exact_string(map, key, expected, field) do
    case Map.get(map, key) do
      ^expected ->
        :ok

      nil ->
        {:error, {:invalid_request, "#{field}.#{key} is required."}}

      _other ->
        {:error, {:invalid_request, "#{field}.#{key} must be \"#{expected}\"."}}
    end
  end

  defp required_string(params, field, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    case Map.get(params, field) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_request, "#{prefix}#{field} is required."}}
        else
          {:ok, value}
        end

      _other ->
        {:error, {:invalid_request, "#{prefix}#{field} is required."}}
    end
  end

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp positive_integer(value, _field) when is_integer(value) and value >= 1, do: {:ok, value}

  defp positive_integer(_value, field) do
    {:error, {:invalid_request, "#{field} must be a positive integer."}}
  end

  defp vault_id_at_index(value, index) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, {:invalid_request, "vault_ids.#{index} is required."}}
    else
      {:ok, value}
    end
  end

  defp vault_id_at_index(_value, index),
    do: {:error, {:invalid_request, "vault_ids.#{index} is required."}}

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
