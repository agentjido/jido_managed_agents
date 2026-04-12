defmodule JidoManagedAgentsWeb.ConsoleData do
  @moduledoc false

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.SessionEvent

  def list_agents(actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.load(AgentCatalog.latest_version_load())
    |> Ash.read!()
  end

  def fetch_agent(id, actor),
    do: AgentCatalog.fetch_agent(id, actor, AgentCatalog.latest_version_load())

  def list_agent_versions(%Agent{} = agent, actor), do: AgentCatalog.list_versions(agent, actor)

  def list_agent_sessions(agent_id, actor) do
    Session
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.load([:agent, :agent_version, :environment, :vaults, :threads])
    |> Ash.read!()
  end

  def list_environments(actor) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!()
  end

  def fetch_environment(id, actor) do
    Environment
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Agents)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Environment{} = environment} -> {:ok, environment}
      {:error, error} -> {:error, error}
    end
  end

  def list_skills(actor) do
    Skill
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.load(:latest_version_number)
    |> Ash.read!()
  end

  def list_vaults(actor) do
    Vault
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!()
  end

  def fetch_vault(id, actor) do
    Vault
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Integrations)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Vault{} = vault} -> {:ok, vault}
      {:error, error} -> {:error, error}
    end
  end

  def count_credentials(actor) do
    Credential
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.read!()
    |> length()
  end

  def list_sessions(actor, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    Session
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> Ash.Query.sort(updated_at: :desc)
    |> maybe_limit(limit)
    |> Ash.Query.load([:agent, :agent_version, :environment, :vaults, threads: [:agent]])
    |> Ash.read!()
  end

  def fetch_session(id, actor) do
    Session
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Sessions)
    |> Ash.Query.load([
      :agent,
      :agent_version,
      :environment,
      :vaults,
      threads: [:agent, :agent_version]
    ])
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Session{} = session} -> {:ok, session}
      {:error, error} -> {:error, error}
    end
  end

  def list_session_events(%Session{} = session, actor, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    thread_id = Keyword.get(opts, :thread_id)

    SessionEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> filter_session_events(session.id, thread_id)
    |> Ash.Query.sort(sequence: :desc)
    |> maybe_limit(limit)
    |> Ash.read!()
    |> Enum.reverse()
  end

  def pending_sessions_count(actor) do
    actor
    |> list_sessions(limit: 100)
    |> Enum.count(&JidoManagedAgentsWeb.ConsoleHelpers.requires_action?(&1.stop_reason))
  end

  defp filter_session_events(query, session_id, nil) do
    Ash.Query.filter(query, session_id == ^session_id)
  end

  defp filter_session_events(query, session_id, thread_id) do
    Ash.Query.filter(query, session_id == ^session_id and session_thread_id == ^thread_id)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: Ash.Query.limit(query, limit)
end
