defmodule JidoManagedAgents.Integrations.VaultDefinition do
  @moduledoc """
  Normalization and serialization helpers for `/v1` vault payloads.
  """

  alias JidoManagedAgents.Integrations.Vault

  @spec normalize_create_payload(map()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, name} <- required_name(params),
         {:ok, description} <- optional_string(Map.get(params, "description"), "description"),
         {:ok, display_metadata} <-
           map_value(Map.get(params, "display_metadata"), default: %{}, field: "display_metadata"),
         {:ok, metadata} <-
           map_value(Map.get(params, "metadata"), default: %{}, field: "metadata") do
      display_metadata =
        display_metadata
        |> stringify_keys_deep()
        |> put_display_name(Map.get(params, "display_name"), name)

      {:ok,
       %{
         name: name,
         description: description,
         display_metadata: display_metadata,
         metadata: stringify_keys_deep(metadata)
       }}
    end
  end

  def normalize_create_payload(_params) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec serialize_vault(Vault.t()) :: map()
  def serialize_vault(%Vault{} = vault) do
    display_metadata = stringify_keys_deep(vault.display_metadata || %{})

    %{
      id: vault.id,
      type: "vault",
      name: vault.name,
      display_name: Map.get(display_metadata, "display_name", vault.name),
      description: vault.description,
      display_metadata: display_metadata,
      metadata: stringify_keys_deep(vault.metadata || %{}),
      created_at: vault.created_at,
      updated_at: vault.updated_at
    }
  end

  defp required_name(params) do
    case Map.get(params, "name") || Map.get(params, "display_name") do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_request, "name or display_name is required."}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:invalid_request, "name or display_name is required."}}
    end
  end

  defp put_display_name(display_metadata, nil, name),
    do: Map.put_new(display_metadata, "display_name", name)

  defp put_display_name(display_metadata, display_name, _name),
    do: Map.put(display_metadata, "display_name", display_name)

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp stringify_top_level_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys_deep(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys_deep(value)} end)
  end

  defp stringify_keys_deep(values) when is_list(values) do
    Enum.map(values, &stringify_keys_deep/1)
  end

  defp stringify_keys_deep(value), do: value
end
