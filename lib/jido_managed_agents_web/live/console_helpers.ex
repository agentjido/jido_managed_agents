defmodule JidoManagedAgentsWeb.ConsoleHelpers do
  @moduledoc false

  def error_message({:invalid_request, message}), do: message
  def error_message({:conflict, message}), do: message
  def error_message(:not_found), do: "The requested record was not found."
  def error_message(%{errors: [error | _rest]}), do: error_message(error)
  def error_message(%{message: message}) when is_binary(message), do: message
  def error_message(error) when is_exception(error), do: Exception.message(error)
  def error_message(error) when is_binary(error), do: error
  def error_message(error), do: inspect(error)

  def parse_json_field(value, default \\ %{})

  def parse_json_field(value, default) when value in [nil, ""], do: {:ok, default}

  def parse_json_field(value, _default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      {:ok, _other} -> {:error, "JSON input must decode to an object."}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def parse_json_field(_value, _default), do: {:error, "JSON input must be a string."}

  def pretty_json(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  def pretty_json(_value), do: "{}"

  def blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def blank_to_nil(value), do: value

  def compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc ->
        acc

      {_key, %{} = value}, acc when map_size(value) == 0 ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  def maybe_put_nested(map, _key, nested) when nested == %{}, do: map
  def maybe_put_nested(map, key, nested), do: Map.put(map, key, nested)

  def format_timestamp(nil), do: "Pending"

  def format_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M UTC")
  end
end
