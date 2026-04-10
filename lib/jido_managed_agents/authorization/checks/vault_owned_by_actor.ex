defmodule JidoManagedAgents.Authorization.Checks.VaultOwnedByActor do
  @moduledoc """
  Matches subjects that reference a vault owned by the current actor.
  """

  use Ash.Policy.SimpleCheck

  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Vault

  require Ash.Query

  @impl true
  def describe(opts) do
    "referenced #{Keyword.get(opts, :attribute, :vault_id)} belongs to the actor"
  end

  @impl true
  def match?(%{id: actor_id}, %{subject: %Ash.Changeset{} = changeset}, opts)
      when is_binary(actor_id) do
    attribute = Keyword.get(opts, :attribute, :vault_id)

    case Ash.Changeset.fetch_argument_or_attribute(changeset, attribute) do
      {:ok, vault_id} when is_binary(vault_id) ->
        Vault
        |> Ash.Query.filter(id == ^vault_id and user_id == ^actor_id)
        |> Ash.exists?(authorize?: false, domain: Integrations)

      _ ->
        false
    end
  end

  def match?(_, _, _), do: false
end
