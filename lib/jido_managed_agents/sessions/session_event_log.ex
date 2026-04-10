defmodule JidoManagedAgents.Sessions.SessionEventLog do
  @moduledoc """
  Transactional append helpers for durable session events.
  """

  require Ash.Query

  alias JidoManagedAgents.Repo
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionLock,
    SessionThread,
    SessionThreads
  }

  @status_event_types %{
    idle: "session.status_idle",
    running: "session.status_running"
  }

  @spec append_user_events(Session.t(), [map()], struct() | nil) ::
          {:ok, [SessionEvent.t()]} | {:error, term()}
  def append_user_events(%Session{} = session, event_attrs, actor) when is_list(event_attrs) do
    SessionLock.with_lock(session.id, fn ->
      Ash.transact([Session, SessionEvent], fn ->
        with {:ok, %Session{} = locked_session} <- locked_session(session.id, actor),
             :ok <- ensure_appendable(locked_session),
             {:ok, events} <- append_events_after_lock(locked_session, actor, event_attrs) do
          events
        end
      end)
    end)
  end

  @spec record_status_transition(Session.t(), atom(), struct() | nil) ::
          {:ok, SessionEvent.t()} | {:error, term()}
  def record_status_transition(%Session{} = session, status, actor) when is_atom(status) do
    with {:ok, type} <- event_type_for_status(status),
         :ok <- lock_session(session.id),
         {:ok, [event]} <-
           append_events_after_lock(session, actor, [
             %{
               type: type,
               content: [],
               payload: %{"status" => Atom.to_string(status)},
               processed_at: nil,
               stop_reason: session.stop_reason
             }
           ]) do
      {:ok, event}
    end
  end

  @spec list_events(Session.t(), %{limit: pos_integer(), after: integer()}, struct() | nil) ::
          {:ok, {[SessionEvent.t()], boolean()}} | {:error, term()}
  def list_events(%Session{} = session, %{limit: limit, after: after_sequence}, actor)
      when is_integer(limit) and limit > 0 and is_integer(after_sequence) do
    query =
      SessionEvent
      |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
      |> Ash.Query.filter(session_id == ^session.id and sequence > ^after_sequence)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.limit(limit + 1)

    with {:ok, events} <- Ash.read(query) do
      {page, remainder} = Enum.split(events, limit)
      {:ok, {page, remainder != []}}
    end
  end

  @spec list_thread_events(
          SessionThread.t(),
          %{limit: pos_integer(), after: integer()},
          struct() | nil
        ) ::
          {:ok, {[SessionEvent.t()], boolean()}} | {:error, term()}
  def list_thread_events(
        %SessionThread{} = thread,
        %{limit: limit, after: after_sequence},
        actor
      )
      when is_integer(limit) and limit > 0 and is_integer(after_sequence) do
    query =
      SessionEvent
      |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
      |> Ash.Query.filter(
        session_id == ^thread.session_id and
          session_thread_id == ^thread.id and
          sequence > ^after_sequence
      )
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.limit(limit + 1)

    with {:ok, events} <- Ash.read(query) do
      {page, remainder} = Enum.split(events, limit)
      {:ok, {page, remainder != []}}
    end
  end

  @spec stream_scope(SessionEvent.t()) :: :both | :thread
  def stream_scope(%SessionEvent{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "stream_scope") || Map.get(metadata, :stream_scope) do
      "thread" -> :thread
      :thread -> :thread
      _other -> :both
    end
  end

  def stream_scope(%SessionEvent{}), do: :both

  defp locked_session(session_id, actor) do
    with :ok <- lock_session(session_id) do
      load_session(session_id, actor)
    end
  end

  defp load_session(session_id, actor) do
    query = Ash.Query.for_read(Session, :by_id, %{id: session_id}, ash_opts(actor))

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Session{} = session} -> {:ok, session}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_appendable(%Session{status: status}) when status in [:idle, :running], do: :ok

  defp ensure_appendable(%Session{}) do
    {:error, {:invalid_request, "Session is not accepting new events."}}
  end

  defp append_events_after_lock(%Session{} = session, actor, event_attrs)
       when is_list(event_attrs) do
    next_sequence = next_sequence(session.id)

    event_attrs
    |> Enum.with_index(next_sequence)
    |> Enum.reduce_while({:ok, []}, fn {attrs, sequence}, {:ok, acc} ->
      case create_event(session, actor, attrs, sequence) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, error} -> {:error, error}
    end
  end

  defp create_event(%Session{} = session, actor, attrs, sequence) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:user_id, session.user_id)
      |> Map.put(:session_id, session.id)
      |> Map.put(:sequence, sequence)
      |> Map.put_new(:content, [])
      |> Map.put_new(:payload, %{})
      |> Map.put_new(:metadata, %{})
      |> maybe_put_primary_thread_id(session.id)
      |> put_stream_scope()

    SessionEvent
    |> Ash.Changeset.for_create(:create, attrs, ash_opts(actor))
    |> Ash.create()
  end

  defp event_type_for_status(status) do
    case @status_event_types[status] do
      nil -> {:error, {:invalid_request, "Unsupported session status transition."}}
      type -> {:ok, type}
    end
  end

  defp lock_session(session_id) do
    Repo.query!(
      "SELECT id FROM sessions WHERE id = $1 FOR UPDATE",
      [dump_uuid!(session_id)]
    )

    :ok
  end

  defp next_sequence(session_id) do
    %Postgrex.Result{rows: [[sequence]]} =
      Repo.query!(
        "SELECT COALESCE(MAX(sequence) + 1, 0) FROM session_events WHERE session_id = $1",
        [dump_uuid!(session_id)]
      )

    sequence
  end

  defp ash_opts(nil), do: [authorize?: false, domain: Sessions]
  defp ash_opts(actor), do: [actor: actor, domain: Sessions]

  defp maybe_put_primary_thread_id(attrs, session_id) do
    case Map.get(attrs, :session_thread_id) || Map.get(attrs, "session_thread_id") do
      nil ->
        case SessionThreads.primary_thread_id(session_id) do
          thread_id when is_binary(thread_id) -> Map.put(attrs, :session_thread_id, thread_id)
          _other -> attrs
        end

      _thread_id ->
        attrs
    end
  end

  defp put_stream_scope(attrs) do
    metadata =
      attrs
      |> Map.get(:metadata)
      |> case do
        metadata when is_map(metadata) -> metadata
        _other -> %{}
      end
      |> Map.put_new("stream_scope", "both")

    Map.put(attrs, :metadata, metadata)
  end

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
