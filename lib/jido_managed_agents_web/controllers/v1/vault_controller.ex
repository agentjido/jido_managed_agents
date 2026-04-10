defmodule JidoManagedAgentsWeb.V1.VaultController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Integrations.VaultDefinition
  alias Plug.Conn

  def create(conn, params) do
    with {:ok, attrs} <- VaultDefinition.normalize_create_payload(params),
         {:ok, %Vault{} = vault} <- create_vault(conn, attrs) do
      conn
      |> Conn.put_status(:created)
      |> render_object(VaultDefinition.serialize_vault(vault))
    end
  end

  def index(conn, _params) do
    query =
      Vault
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Integrations))
      |> Ash.Query.sort(created_at: :desc)

    with {:ok, vaults} <- Ash.read(query) do
      render_list(conn, vaults, &VaultDefinition.serialize_vault/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, id) do
      render_object(conn, VaultDefinition.serialize_vault(vault))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, id),
         :ok <- destroy_vault(conn, vault) do
      Conn.send_resp(conn, :no_content, "")
    end
  end

  defp fetch_vault(conn, id) do
    query =
      Vault
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(conn, domain: Integrations))

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Vault{} = vault} -> {:ok, vault}
      {:error, error} -> {:error, error}
    end
  end

  defp create_vault(conn, attrs) do
    Vault
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, Keyword.fetch!(ash_opts(conn), :actor).id),
      ash_opts(conn, domain: Integrations)
    )
    |> Ash.create()
  end

  defp destroy_vault(conn, %Vault{} = vault) do
    opts = ash_opts(conn, domain: Integrations)

    case Ash.transact([Vault, Credential], fn ->
           with {:ok, credentials} <- list_vault_credentials(vault.id, opts),
                :ok <- destroy_credentials(credentials, opts),
                :ok <- destroy_record(vault, opts) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp list_vault_credentials(vault_id, opts) do
    query =
      Credential
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(vault_id == ^vault_id)

    Ash.read(query)
  end

  defp destroy_credentials(credentials, opts) do
    Enum.reduce_while(credentials, :ok, fn credential, :ok ->
      case destroy_record(credential, opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp destroy_record(record, opts) do
    case record
         |> Ash.Changeset.for_destroy(:destroy, %{}, opts)
         |> Ash.destroy() do
      :ok -> :ok
      {:ok, _destroyed_record} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
