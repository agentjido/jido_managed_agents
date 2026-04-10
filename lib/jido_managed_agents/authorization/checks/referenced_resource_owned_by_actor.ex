defmodule JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor do
  @moduledoc """
  Matches changesets whose referenced resource belongs to the current actor and,
  when configured, whose referenced resource fields match sibling changeset values.
  """

  use Ash.Policy.SimpleCheck

  import Ash.Expr

  require Ash.Query

  @impl true
  def describe(opts) do
    "referenced #{Keyword.fetch!(opts, :attribute)} belongs to the actor"
  end

  @impl true
  def match?(%{id: actor_id}, %{subject: %Ash.Changeset{} = changeset}, opts)
      when is_binary(actor_id) do
    attribute = Keyword.fetch!(opts, :attribute)

    case Ash.Changeset.fetch_argument_or_attribute(changeset, attribute) do
      {:ok, nil} ->
        Keyword.get(opts, :allow_nil?, false)

      {:ok, referenced_id} ->
        case build_query(changeset, actor_id, referenced_id, opts) do
          {:ok, query} ->
            Ash.exists?(query, authorize?: false, domain: Keyword.fetch!(opts, :domain))

          :error ->
            false
        end

      :error ->
        false
    end
  end

  def match?(_, _, _), do: false

  defp build_query(changeset, actor_id, referenced_id, opts) do
    owner_attribute = Keyword.get(opts, :owner_attribute, :user_id)

    query =
      opts
      |> Keyword.fetch!(:resource)
      |> Ash.Query.filter(^ref(:id) == ^referenced_id)
      |> Ash.Query.filter(^ref(owner_attribute) == ^actor_id)

    Enum.reduce_while(Keyword.get(opts, :matches, []), {:ok, query}, fn
      {resource_attribute, changeset_attribute}, {:ok, query} ->
        case Ash.Changeset.fetch_argument_or_attribute(changeset, changeset_attribute) do
          {:ok, value} ->
            {:cont, {:ok, Ash.Query.filter(query, ^ref(resource_attribute) == ^value)}}

          :error ->
            {:halt, :error}
        end
    end)
  end
end
