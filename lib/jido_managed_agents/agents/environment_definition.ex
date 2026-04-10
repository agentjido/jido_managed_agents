defmodule JidoManagedAgents.Agents.EnvironmentDefinition do
  @moduledoc """
  Normalization and serialization helpers for Anthropic-compatible environment
  payloads.

  The public `/v1` payload mirrors Anthropic's cloud-environment contract, but
  this application executes v1 sessions locally through supervised Jido runtime
  processes. In v1 only the narrow config fields that map cleanly to local
  runtime semantics are supported.
  """

  alias JidoManagedAgents.Agents.Environment

  @allowed_config_keys MapSet.new(["networking", "type"])
  @allowed_networking_keys MapSet.new(["type"])
  @allowed_networking_types MapSet.new(["restricted", "unrestricted"])

  @spec normalize_create_payload(map()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, name} <- required_string(params, "name"),
         {:ok, config} <- normalize_config(Map.get(params, "config"), field: "config"),
         {:ok, description} <- optional_string(Map.get(params, "description"), "description"),
         {:ok, metadata} <-
           map_value(Map.get(params, "metadata"), default: %{}, field: "metadata") do
      {:ok,
       %{
         name: name,
         description: description,
         config: config,
         metadata: stringify_keys_deep(metadata)
       }}
    end
  end

  def normalize_create_payload(_params) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec normalize_update_payload(map(), struct()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_update_payload(params, %Environment{} = environment) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, name} <- merge_required_string(params, "name", environment.name),
         {:ok, description} <-
           merge_optional_string(params, "description", environment.description),
         {:ok, config} <- merge_config(params, environment.config),
         {:ok, metadata} <- merge_metadata(params, environment.metadata) do
      {:ok,
       %{
         name: name,
         description: description,
         config: config,
         metadata: metadata
       }}
    end
  end

  def normalize_update_payload(_params, _environment) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec normalize_config(map() | nil, keyword()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_config(value, opts \\ [])

  def normalize_config(nil, opts) do
    {:error, {:invalid_request, "#{Keyword.get(opts, :field, "config")} is required."}}
  end

  def normalize_config(value, opts) when is_map(value) do
    value = stringify_top_level_keys(value)
    field = Keyword.get(opts, :field, "config")

    with :ok <- reject_extra_keys(value, @allowed_config_keys, field),
         :ok <- require_exact_string(value, "type", "cloud", field),
         {:ok, networking} <- required_map(Map.get(value, "networking"), "#{field}.networking"),
         networking <- stringify_top_level_keys(networking),
         :ok <- reject_extra_keys(networking, @allowed_networking_keys, "#{field}.networking"),
         {:ok, networking_type} <-
           required_string(networking, "type", prefix: "#{field}.networking."),
         :ok <- validate_networking_type(networking_type, "#{field}.networking.type") do
      {:ok,
       %{
         "type" => "cloud",
         "networking" => %{"type" => networking_type}
       }}
    end
  end

  def normalize_config(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.get(opts, :field, "config")} must be an object."}}
  end

  @spec serialize_environment(struct()) :: map()
  def serialize_environment(%Environment{} = environment) do
    %{
      id: environment.id,
      type: "environment",
      name: environment.name,
      description: environment.description,
      config: serialize_config(environment.config),
      metadata: stringify_keys_deep(environment.metadata || %{}),
      archived_at: environment.archived_at,
      created_at: environment.created_at,
      updated_at: environment.updated_at
    }
  end

  defp merge_required_string(params, field, current) do
    if Map.has_key?(params, field) do
      required_string(params, field)
    else
      {:ok, current}
    end
  end

  defp merge_optional_string(params, field, current) do
    if Map.has_key?(params, field) do
      optional_string(Map.get(params, field), field)
    else
      {:ok, current}
    end
  end

  defp merge_config(params, current) do
    if Map.has_key?(params, "config") do
      normalize_config(Map.get(params, "config"), field: "config")
    else
      normalize_existing_config(current)
    end
  end

  defp merge_metadata(params, current) do
    if Map.has_key?(params, "metadata") do
      with {:ok, metadata} <- required_map(Map.get(params, "metadata"), "metadata") do
        {:ok, merge_metadata_values(stringify_keys_deep(current || %{}), metadata)}
      end
    else
      {:ok, stringify_keys_deep(current || %{})}
    end
  end

  defp merge_metadata_values(current, incoming) do
    incoming
    |> stringify_top_level_keys()
    |> Enum.reduce(current, fn
      {key, ""}, metadata -> Map.delete(metadata, key)
      {key, value}, metadata -> Map.put(metadata, key, value)
    end)
  end

  defp normalize_existing_config(current) do
    case normalize_config(current, field: "config") do
      {:ok, normalized_config} -> {:ok, normalized_config}
      {:error, _error} -> {:ok, stringify_keys_deep(current || %{})}
    end
  end

  defp serialize_config(config) do
    case normalize_config(config, field: "config") do
      {:ok, normalized_config} -> normalized_config
      {:error, _error} -> stringify_keys_deep(config || %{})
    end
  end

  defp validate_networking_type(type, field) do
    if MapSet.member?(@allowed_networking_types, type) do
      :ok
    else
      {:error, {:invalid_request, "#{field} must be \"restricted\" or \"unrestricted\"."}}
    end
  end

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

  defp reject_extra_keys(map, allowed_keys, field) do
    case map
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&MapSet.member?(allowed_keys, &1))
         |> Enum.sort() do
      [] ->
        :ok

      [unsupported_key | _rest] ->
        {:error, {:invalid_request, "#{field}.#{unsupported_key} is not supported in v1."}}
    end
  end

  defp required_string(params, field, opts \\ []) do
    value = Map.get(params, field)
    prefix = Keyword.get(opts, :prefix, "")

    if present_string?(value) do
      {:ok, value}
    else
      {:error, {:invalid_request, "#{prefix}#{field} is required."}}
    end
  end

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp required_map(nil, field), do: {:error, {:invalid_request, "#{field} is required."}}
  defp required_map(value, _field) when is_map(value), do: {:ok, value}

  defp required_map(_value, field) do
    {:error, {:invalid_request, "#{field} must be an object."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp present_string?(value) when is_binary(value) do
    String.trim(value) != ""
  end

  defp present_string?(_value), do: false

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
