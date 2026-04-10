defmodule JidoManagedAgents.Sessions.SessionStream do
  @moduledoc """
  Small PubSub interface for replayable session event streams.

  LiveViews and other in-process consumers can subscribe to a session topic and
  receive persisted session events as they commit, plus closure notices for
  archived or deleted sessions.
  """

  alias JidoManagedAgents.Sessions.{Session, SessionEvent, SessionEventLog}
  alias Phoenix.PubSub

  @type close_status :: :archived | :deleted

  @type message ::
          {:session_event, SessionEvent.t()}
          | {:thread_event, SessionEvent.t()}
          | {:session_closed, %{session_id: String.t(), status: close_status()}}

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session_id) when is_binary(session_id) do
    PubSub.subscribe(JidoManagedAgents.PubSub, session_topic(session_id))
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    PubSub.unsubscribe(JidoManagedAgents.PubSub, session_topic(session_id))
  end

  @spec subscribe_thread(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe_thread(session_id, thread_id)
      when is_binary(session_id) and is_binary(thread_id) do
    PubSub.subscribe(JidoManagedAgents.PubSub, thread_topic(session_id, thread_id))
  end

  @spec unsubscribe_thread(String.t(), String.t()) :: :ok
  def unsubscribe_thread(session_id, thread_id)
      when is_binary(session_id) and is_binary(thread_id) do
    PubSub.unsubscribe(JidoManagedAgents.PubSub, thread_topic(session_id, thread_id))
  end

  @spec broadcast_event(SessionEvent.t()) :: :ok
  def broadcast_event(%SessionEvent{} = event) do
    maybe_broadcast_session_event(event)
    maybe_broadcast_thread_event(event)
    :ok
  end

  @spec broadcast_closed(Session.t()) :: :ok
  def broadcast_closed(%Session{status: status} = session) when status in [:archived, :deleted] do
    PubSub.broadcast(
      JidoManagedAgents.PubSub,
      session_topic(session.id),
      {:session_closed, %{session_id: session.id, status: status}}
    )
  end

  @spec session_event_visible?(SessionEvent.t()) :: boolean()
  def session_event_visible?(%SessionEvent{} = event) do
    SessionEventLog.stream_scope(event) == :both
  end

  defp maybe_broadcast_session_event(%SessionEvent{} = event) do
    if session_event_visible?(event) do
      PubSub.broadcast(
        JidoManagedAgents.PubSub,
        session_topic(event.session_id),
        {:session_event, event}
      )
    end
  end

  defp maybe_broadcast_thread_event(%SessionEvent{session_thread_id: thread_id} = event)
       when is_binary(thread_id) do
    PubSub.broadcast(
      JidoManagedAgents.PubSub,
      thread_topic(event.session_id, thread_id),
      {:thread_event, event}
    )
  end

  defp maybe_broadcast_thread_event(_event), do: :ok

  defp session_topic(session_id), do: "sessions:#{session_id}:stream"

  defp thread_topic(session_id, thread_id),
    do: "sessions:#{session_id}:threads:#{thread_id}:stream"
end
