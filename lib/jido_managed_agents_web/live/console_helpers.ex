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

  def short_id(nil), do: "unknown"
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  def status_label(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  def status_label(status) when is_binary(status), do: String.capitalize(status)
  def status_label(_status), do: "Unknown"

  def truthy?(value), do: value in [true, "true", 1, "1"]

  def requires_action?(stop_reason), do: requires_action_event_ids(stop_reason) != []

  def requires_action_event_ids(%{} = stop_reason) do
    if payload_value(stop_reason, "type") == "requires_action" do
      stop_reason
      |> payload_value("event_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
    else
      []
    end
  end

  def requires_action_event_ids(_stop_reason), do: []

  def payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || existing_atom_value(payload, key)
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  def payload_value(_payload, _key), do: nil

  def text_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  def text_content(_content), do: ""

  def pretty_data(nil), do: "(none)"
  def pretty_data(value) when is_binary(value), do: value

  def pretty_data(value) when is_map(value) or is_list(value) do
    Jason.encode!(value, pretty: true)
  end

  def pretty_data(value), do: inspect(value, pretty: true)

  def session_model(%{agent_version: %{model: model}}) when is_map(model) do
    payload_value(model, "id") || payload_value(model, "model_id") || "Unknown model"
  end

  def session_model(_session), do: "Unknown model"

  def agent_model(%{model: model}) when is_map(model) do
    payload_value(model, "id") || payload_value(model, "model_id") || "Unknown model"
  end

  def agent_model(%{latest_version: %{model: model}}) when is_map(model) do
    payload_value(model, "id") || payload_value(model, "model_id") || "Unknown model"
  end

  def agent_model(_agent), do: "Unknown model"

  def networking_label(%{config: config}) when is_map(config) do
    get_in(config, ["networking", "type"]) || get_in(config, [:networking, :type]) || "restricted"
  end

  def networking_label(_environment), do: "restricted"

  defp existing_atom_value(payload, key) do
    key
    |> String.to_existing_atom()
    |> then(&Map.get(payload, &1))
  end
end
