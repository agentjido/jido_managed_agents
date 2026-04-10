defmodule JidoManagedAgentsWeb.V1.CredentialController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.CredentialDefinition
  alias JidoManagedAgents.Integrations.Vault
  alias Plug.Conn

  def create(conn, %{"vault_id" => vault_id} = params) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, vault_id),
         {:ok, attrs} <- CredentialDefinition.normalize_create_payload(params),
         {:ok, %Credential{} = credential} <- create_credential(conn, vault, attrs) do
      conn
      |> Conn.put_status(:created)
      |> render_object(CredentialDefinition.serialize_credential(credential))
    end
  end

  def index(conn, %{"vault_id" => vault_id}) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, vault_id),
         {:ok, credentials} <- list_credentials(conn, vault) do
      render_list(conn, credentials, &CredentialDefinition.serialize_credential/1)
    end
  end

  def show(conn, %{"vault_id" => vault_id, "id" => id}) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, vault_id),
         {:ok, %Credential{} = credential} <- fetch_credential(conn, vault, id) do
      render_object(conn, CredentialDefinition.serialize_credential(credential))
    end
  end

  def update(conn, %{"vault_id" => vault_id, "id" => id} = params) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, vault_id),
         {:ok, %Credential{} = credential} <- fetch_credential(conn, vault, id),
         {:ok, attrs} <- CredentialDefinition.normalize_update_payload(params, credential),
         {:ok, %Credential{} = updated_credential} <- update_credential(conn, credential, attrs) do
      render_object(conn, CredentialDefinition.serialize_credential(updated_credential))
    end
  end

  def delete(conn, %{"vault_id" => vault_id, "id" => id}) do
    with {:ok, %Vault{} = vault} <- fetch_vault(conn, vault_id),
         {:ok, %Credential{} = credential} <- fetch_credential(conn, vault, id),
         :ok <- destroy_credential(conn, credential) do
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

  defp fetch_credential(conn, vault, id) do
    query =
      Credential
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(conn, domain: Integrations))
      |> Ash.Query.filter(vault_id == ^vault.id)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Credential{} = credential} -> {:ok, credential}
      {:error, error} -> {:error, error}
    end
  end

  defp create_credential(conn, vault, attrs) do
    Credential
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :vault_id, vault.id),
      ash_opts(conn, domain: Integrations)
    )
    |> Ash.create()
  end

  defp list_credentials(conn, vault) do
    query =
      Credential
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Integrations))
      |> Ash.Query.filter(vault_id == ^vault.id)
      |> Ash.Query.sort(created_at: :desc)

    Ash.read(query)
  end

  defp update_credential(conn, credential, attrs) do
    credential
    |> Ash.Changeset.for_update(:update, attrs, ash_opts(conn, domain: Integrations))
    |> Ash.update()
  end

  defp destroy_credential(conn, credential) do
    case credential
         |> Ash.Changeset.for_destroy(:destroy, %{}, ash_opts(conn, domain: Integrations))
         |> Ash.destroy() do
      :ok -> :ok
      {:ok, _destroyed_credential} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
