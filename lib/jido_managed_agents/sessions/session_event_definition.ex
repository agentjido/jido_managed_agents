defmodule JidoManagedAgents.Sessions.SessionEventDefinition do
  @moduledoc """
  Normalization and serialization helpers for the public session event API.
  """

  require Ash.Query

  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.{Session, SessionEvent, SessionThread}

  @allowed_user_event_types [
    "user.message",
    "user.interrupt",
    "user.custom_tool_result",
    "user.tool_confirmation"
  ]

  @default_page_size 20
  @max_page_size 100

  @spec normalize_append_payload(map(), Session.t(), struct() | nil) ::
          {:ok, [map()]} | {:error, {:invalid_request, String.t()}}
  def normalize_append_payload(params, %Session{} = session, actor) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, events} <- extract_events(params) do
      events
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {event_params, index}, {:ok, acc} ->
        case normalize_event(event_params, index, session, actor) do
          {:ok, event} -> {:cont, {:ok, [event | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        {:error, error} -> {:error, error}
      end
    end
  end

  def normalize_append_payload(_params, _session, _actor) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec normalize_list_params(map()) :: {:ok, %{limit: pos_integer(), after: integer()}}
  def normalize_list_params(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, limit} <- positive_integer(Map.get(params, "limit"), "limit", @default_page_size),
         {:ok, after_sequence} <- integer_with_default(Map.get(params, "after"), "after", -1),
         :ok <- validate_after(after_sequence) do
      {:ok, %{limit: limit, after: after_sequence}}
    end
  end

  @spec normalize_stream_params(map()) :: {:ok, %{after: integer()}}
  def normalize_stream_params(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, after_sequence} <- integer_with_default(Map.get(params, "after"), "after", -1),
         :ok <- validate_after(after_sequence) do
      {:ok, %{after: after_sequence}}
    end
  end

  @spec serialize_event(SessionEvent.t()) :: map()
  def serialize_event(%SessionEvent{} = event) do
    %{
      id: event.id,
      type: event.type,
      session_id: event.session_id,
      session_thread_id: event.session_thread_id,
      sequence: event.sequence,
      content: event.content,
      payload: event.payload,
      processed_at: event.processed_at,
      stop_reason: event.stop_reason,
      created_at: event.created_at
    }
  end

  defp extract_events(%{"events" => events}) when is_list(events) and events != [],
    do: {:ok, events}

  defp extract_events(%{"events" => []}) do
    {:error, {:invalid_request, "events must contain at least one event."}}
  end

  defp extract_events(%{"events" => _other}) do
    {:error, {:invalid_request, "events must be an array of event objects."}}
  end

  defp extract_events(%{} = params), do: {:ok, [params]}

  defp normalize_event(%{} = params, index, %Session{} = session, actor) do
    params = stringify_top_level_keys(params)
    prefix = field_prefix(index)

    with {:ok, type} <- required_user_event_type(Map.get(params, "type"), prefix),
         {:ok, session_thread_id} <-
           optional_session_thread_id(
             Map.get(params, "session_thread_id"),
             prefix,
             session,
             actor
           ),
         {:ok, content} <- optional_content(Map.get(params, "content"), prefix),
         {:ok, payload} <- optional_map(Map.get(params, "payload"), prefix <> "payload", %{}),
         {:ok, payload} <- normalize_user_event_payload(type, payload, params, prefix),
         {:ok, processed_at} <-
           optional_datetime(Map.get(params, "processed_at"), prefix <> "processed_at"),
         {:ok, stop_reason} <-
           optional_nullable_map(Map.get(params, "stop_reason"), prefix <> "stop_reason") do
      {:ok,
       %{
         session_thread_id: session_thread_id,
         type: type,
         content: content,
         payload: payload,
         processed_at: processed_at,
         stop_reason: stop_reason
       }}
    end
  end

  defp normalize_event(_params, index, _session, _actor) do
    {:error, {:invalid_request, "#{event_pointer(index)} must be an object."}}
  end

  defp required_user_event_type(type, _prefix) when type in @allowed_user_event_types,
    do: {:ok, type}

  defp required_user_event_type(_type, prefix) do
    joined_types = Enum.join(@allowed_user_event_types, ", ")
    {:error, {:invalid_request, "#{prefix}type must be one of: #{joined_types}."}}
  end

  defp optional_session_thread_id(nil, _prefix, _session, _actor), do: {:ok, nil}

  defp optional_session_thread_id(session_thread_id, prefix, session, actor)
       when is_binary(session_thread_id) do
    if String.trim(session_thread_id) == "" do
      {:error, {:invalid_request, "#{prefix}session_thread_id is required."}}
    else
      query =
        SessionThread
        |> Ash.Query.for_read(:by_id, %{id: session_thread_id}, ash_opts(actor))
        |> Ash.Query.filter(session_id == ^session.id)

      case Ash.read_one(query) do
        {:ok, %SessionThread{} = thread} -> {:ok, thread.id}
        {:ok, nil} -> {:error, {:invalid_request, "#{prefix}session_thread_id was not found."}}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp optional_session_thread_id(_session_thread_id, prefix, _session, _actor) do
    {:error, {:invalid_request, "#{prefix}session_thread_id must be a string or null."}}
  end

  defp optional_content(nil, _prefix), do: {:ok, []}

  defp optional_content(content, prefix) when is_list(content) do
    case Enum.all?(content, &is_map/1) do
      true -> {:ok, content}
      false -> {:error, {:invalid_request, "#{prefix}content must be an array of objects."}}
    end
  end

  defp optional_content(_content, prefix) do
    {:error, {:invalid_request, "#{prefix}content must be an array of objects."}}
  end

  defp optional_map(nil, _field, default), do: {:ok, default}
  defp optional_map(value, _field, _default) when is_map(value), do: {:ok, value}

  defp optional_map(_value, field, _default) do
    {:error, {:invalid_request, "#{field} must be an object."}}
  end

  defp optional_nullable_map(nil, _field), do: {:ok, nil}
  defp optional_nullable_map(value, _field) when is_map(value), do: {:ok, value}

  defp optional_nullable_map(_value, field) do
    {:error, {:invalid_request, "#{field} must be an object or null."}}
  end

  defp optional_datetime(nil, _field), do: {:ok, nil}

  defp optional_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, {:invalid_request, "#{field} must be an RFC 3339 timestamp or null."}}
    end
  end

  defp optional_datetime(_value, field) do
    {:error, {:invalid_request, "#{field} must be an RFC 3339 timestamp or null."}}
  end

  defp normalize_user_event_payload("user.tool_confirmation", payload, params, prefix) do
    payload =
      payload
      |> stringify_top_level_keys()
      |> Map.put_new("tool_use_id", Map.get(params, "tool_use_id"))
      |> Map.put_new("result", Map.get(params, "result"))
      |> maybe_put("deny_message", Map.get(params, "deny_message"))

    with {:ok, tool_use_id} <-
           required_non_empty_string(
             Map.get(payload, "tool_use_id"),
             prefix <> "tool_use_id"
           ),
         {:ok, result} <- tool_confirmation_result(Map.get(payload, "result"), prefix),
         {:ok, deny_message} <-
           optional_string(Map.get(payload, "deny_message"), prefix <> "deny_message") do
      {:ok,
       payload
       |> Map.put("tool_use_id", tool_use_id)
       |> Map.put("result", result)
       |> maybe_put("deny_message", deny_message)}
    end
  end

  defp normalize_user_event_payload("user.custom_tool_result", payload, params, prefix) do
    payload =
      payload
      |> stringify_top_level_keys()
      |> Map.put_new("custom_tool_use_id", Map.get(params, "custom_tool_use_id"))

    with {:ok, custom_tool_use_id} <-
           required_non_empty_string(
             Map.get(payload, "custom_tool_use_id"),
             prefix <> "custom_tool_use_id"
           ) do
      {:ok, Map.put(payload, "custom_tool_use_id", custom_tool_use_id)}
    end
  end

  defp normalize_user_event_payload(_type, payload, _params, _prefix) do
    {:ok, stringify_top_level_keys(payload)}
  end

  defp required_non_empty_string(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp required_non_empty_string(_value, field) do
    {:error, {:invalid_request, "#{field} is required."}}
  end

  defp tool_confirmation_result(result, _prefix) when result in ["allow", "deny"],
    do: {:ok, result}

  defp tool_confirmation_result(_result, prefix) do
    {:error, {:invalid_request, "#{prefix}result must be allow or deny."}}
  end

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp positive_integer(nil, _field, default), do: {:ok, default}

  defp positive_integer(value, _field, _default)
       when is_integer(value) and value > 0 and value <= @max_page_size,
       do: {:ok, value}

  defp positive_integer(value, field, _default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 and integer <= @max_page_size ->
        {:ok, integer}

      _other ->
        {:error,
         {:invalid_request, "#{field} must be an integer between 1 and #{@max_page_size}."}}
    end
  end

  defp positive_integer(_value, field, _default) do
    {:error, {:invalid_request, "#{field} must be an integer between 1 and #{@max_page_size}."}}
  end

  defp integer_with_default(nil, _field, default), do: {:ok, default}
  defp integer_with_default(value, _field, _default) when is_integer(value), do: {:ok, value}

  defp integer_with_default(value, field, _default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, {:invalid_request, "#{field} must be an integer."}}
    end
  end

  defp integer_with_default(_value, field, _default) do
    {:error, {:invalid_request, "#{field} must be an integer."}}
  end

  defp validate_after(after_sequence) when after_sequence >= -1, do: :ok

  defp validate_after(_after_sequence) do
    {:error, {:invalid_request, "after must be greater than or equal to -1."}}
  end

  defp field_prefix(0), do: ""
  defp field_prefix(index), do: "events.#{index}."
  defp event_pointer(0), do: "event"
  defp event_pointer(index), do: "events.#{index}"

  defp ash_opts(nil), do: [authorize?: false, domain: Sessions]
  defp ash_opts(actor), do: [actor: actor, domain: Sessions]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
