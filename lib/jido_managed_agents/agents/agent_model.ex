defmodule JidoManagedAgents.Agents.AgentModel do
  @moduledoc """
  Normalizes accepted agent model forms for persistence and serializes them for
  API responses or Anthropic-style definition exports.
  """

  @shape_key "__serialization_shape"
  @anthropic_string "anthropic_string"
  @anthropic_object "anthropic_object"
  @provider_string "provider_string"
  @provider_object "provider_object"

  @error_message "model must be a string, an object with id and speed, or an object with provider and id."

  @type normalized_model :: map()

  @spec normalize(term()) :: {:ok, normalized_model()} | {:error, {:invalid_request, String.t()}}
  def normalize(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" ->
        {:ok,
         %{
           "provider" => provider,
           "id" => id,
           @shape_key => @provider_string
         }}

      [_single] ->
        {:ok,
         %{
           "id" => model,
           "speed" => "standard",
           @shape_key => @anthropic_string
         }}

      _ ->
        {:error, {:invalid_request, @error_message}}
    end
  end

  def normalize(model) when is_map(model) do
    model = strip_shape_marker(stringify_keys(model))

    cond do
      present_string?(model["provider"]) and present_string?(model["id"]) ->
        {:ok,
         compact_map(%{
           "provider" => model["provider"],
           "id" => model["id"],
           "speed" => model["speed"],
           @shape_key => @provider_object
         })}

      present_string?(model["id"]) and present_string?(model["speed"]) ->
        {:ok,
         %{
           "id" => model["id"],
           "speed" => model["speed"],
           @shape_key => @anthropic_object
         }}

      true ->
        {:error, {:invalid_request, @error_message}}
    end
  end

  def normalize(_model), do: {:error, {:invalid_request, @error_message}}

  @spec serialize_for_response(term()) :: map() | nil
  def serialize_for_response(nil), do: nil

  def serialize_for_response(model) when is_map(model) do
    model
    |> stringify_keys()
    |> strip_shape_marker()
  end

  @spec serialize_for_definition(term()) :: map() | String.t() | nil
  def serialize_for_definition(nil), do: nil

  def serialize_for_definition(model) when is_map(model) do
    model = stringify_keys(model)
    shape = Map.get(model, @shape_key)
    clean_model = strip_shape_marker(model)

    case {shape, clean_model} do
      {@provider_string, %{"provider" => provider, "id" => id}}
      when is_binary(provider) and is_binary(id) ->
        provider <> ":" <> id

      {@provider_object, %{"provider" => provider, "id" => id} = clean_model}
      when is_binary(provider) and is_binary(id) ->
        compact_map(clean_model)

      {@anthropic_string, %{"id" => id, "speed" => "standard"}} when is_binary(id) ->
        id

      {@anthropic_object, %{"id" => id, "speed" => speed}}
      when is_binary(id) and is_binary(speed) ->
        %{"id" => id, "speed" => speed}

      {_, %{"provider" => provider, "id" => id} = clean_model}
      when is_binary(provider) and is_binary(id) ->
        compact_map(clean_model)

      {_, %{"id" => id, "speed" => speed}}
      when is_binary(id) and is_binary(speed) ->
        %{"id" => id, "speed" => speed}

      _ ->
        clean_model
    end
  end

  @spec error_message() :: String.t()
  def error_message, do: @error_message

  defp compact_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp strip_shape_marker(model), do: Map.delete(model, @shape_key)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
