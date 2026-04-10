defmodule JidoManagedAgentsWeb.V1.AgentController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.AshActor
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Agents.AgentDefinition

  alias Plug.Conn

  def create(conn, params) do
    with {:ok, %Agent{} = agent} <- AgentCatalog.create_from_params(params, AshActor.actor(conn)) do
      conn
      |> Conn.put_status(:created)
      |> render_object(AgentDefinition.serialize_agent(agent))
    end
  end

  def index(conn, _params) do
    query =
      Agent
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: JidoManagedAgents.Agents))
      |> Ash.Query.filter(is_nil(archived_at))
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(AgentCatalog.latest_version_load())

    with {:ok, agents} <- Ash.read(query) do
      render_list(conn, agents, &AgentDefinition.serialize_agent/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, AshActor.actor(conn)) do
      render_object(conn, AgentDefinition.serialize_agent(agent))
    end
  end

  def update(conn, %{"id" => id} = params) do
    actor = AshActor.actor(conn)

    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, actor),
         {:ok, %Agent{} = updated_agent} <- AgentCatalog.update_from_params(agent, params, actor) do
      render_object(conn, AgentDefinition.serialize_agent(updated_agent))
    end
  end

  def versions(conn, %{"id" => id}) do
    actor = AshActor.actor(conn)

    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, actor, []),
         {:ok, versions} <- AgentCatalog.list_versions(agent, actor) do
      render_list(conn, versions, &AgentDefinition.serialize_agent_version(agent, &1))
    end
  end

  def archive(conn, %{"id" => id}) do
    actor = AshActor.actor(conn)

    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, actor),
         {:ok, %Agent{} = archived_agent} <- AgentCatalog.archive(agent, actor) do
      render_object(conn, AgentDefinition.serialize_agent(archived_agent))
    end
  end

  def delete(conn, %{"id" => id}) do
    actor = AshActor.actor(conn)

    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, actor, []),
         :ok <- AgentCatalog.destroy(agent, actor) do
      Conn.send_resp(conn, :no_content, "")
    end
  end
end
