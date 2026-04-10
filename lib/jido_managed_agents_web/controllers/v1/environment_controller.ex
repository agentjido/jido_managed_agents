defmodule JidoManagedAgentsWeb.V1.EnvironmentController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.EnvironmentDefinition
  alias JidoManagedAgents.Agents.EnvironmentLifecycle
  alias Plug.Conn

  def create(conn, params) do
    with {:ok, attrs} <- EnvironmentDefinition.normalize_create_payload(params),
         {:ok, %Environment{} = environment} <- create_environment(conn, attrs) do
      conn
      |> Conn.put_status(:created)
      |> render_object(EnvironmentDefinition.serialize_environment(environment))
    end
  end

  def index(conn, _params) do
    query =
      Environment
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Agents))
      |> Ash.Query.filter(is_nil(archived_at))
      |> Ash.Query.sort(created_at: :desc)

    with {:ok, environments} <- Ash.read(query) do
      render_list(conn, environments, &EnvironmentDefinition.serialize_environment/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Environment{} = environment} <- fetch_environment(conn, id) do
      render_object(conn, EnvironmentDefinition.serialize_environment(environment))
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %Environment{} = environment} <- fetch_environment(conn, id),
         :ok <- ensure_not_archived(environment),
         {:ok, attrs} <- EnvironmentDefinition.normalize_update_payload(params, environment),
         {:ok, %Environment{} = updated_environment} <-
           update_environment(conn, environment, attrs) do
      render_object(conn, EnvironmentDefinition.serialize_environment(updated_environment))
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, %Environment{} = environment} <- fetch_environment(conn, id),
         {:ok, %Environment{} = archived_environment} <- archive_environment(conn, environment) do
      render_object(conn, EnvironmentDefinition.serialize_environment(archived_environment))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Environment{} = environment} <- fetch_environment(conn, id),
         :ok <- ensure_delete_allowed(environment),
         :ok <- destroy_environment(conn, environment) do
      Conn.send_resp(conn, :no_content, "")
    end
  end

  defp fetch_environment(conn, id) do
    query =
      Environment
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(conn, domain: Agents))

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Environment{} = environment} -> {:ok, environment}
      {:error, error} -> {:error, error}
    end
  end

  defp create_environment(conn, attrs) do
    Environment
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, Keyword.fetch!(ash_opts(conn), :actor).id),
      ash_opts(conn, domain: Agents)
    )
    |> Ash.create()
  end

  defp update_environment(conn, environment, attrs) do
    environment
    |> Ash.Changeset.for_update(:update, attrs, ash_opts(conn, domain: Agents))
    |> Ash.update()
  end

  defp archive_environment(_conn, %Environment{archived_at: %DateTime{}} = environment),
    do: {:ok, environment}

  defp archive_environment(conn, %Environment{} = environment) do
    environment
    |> Ash.Changeset.for_update(:archive, %{}, ash_opts(conn, domain: Agents))
    |> Ash.update()
  end

  defp destroy_environment(conn, %Environment{} = environment) do
    case environment
         |> Ash.Changeset.for_destroy(:destroy, %{}, ash_opts(conn, domain: Agents))
         |> Ash.destroy() do
      :ok -> :ok
      {:ok, _destroyed_environment} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_not_archived(%Environment{archived_at: nil}), do: :ok

  defp ensure_not_archived(%Environment{}) do
    {:error, {:invalid_request, "Archived environments are read-only."}}
  end

  defp ensure_delete_allowed(%Environment{} = environment) do
    with {:ok, blockers} <- EnvironmentLifecycle.delete_blockers(environment.id) do
      case EnvironmentLifecycle.delete_conflict_message(blockers) do
        nil -> :ok
        message -> {:error, {:conflict, message}}
      end
    end
  end
end
