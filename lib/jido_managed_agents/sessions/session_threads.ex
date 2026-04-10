defmodule JidoManagedAgents.Sessions.SessionThreads do
  @moduledoc false

  require Ash.Query

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.{Session, SessionThread}

  @spec ensure_primary_thread(Session.t(), struct() | nil, keyword()) ::
          {:ok, SessionThread.t()} | {:error, term()}
  def ensure_primary_thread(%Session{} = session, actor \\ nil, load \\ []) when is_list(load) do
    with {:ok, maybe_thread} <- get_primary_thread(session, actor, load) do
      case maybe_thread do
        %SessionThread{} = thread ->
          {:ok, thread}

        nil ->
          create_primary_thread(session, actor, load)
      end
    end
  end

  @spec get_primary_thread(Session.t(), struct() | nil, keyword()) ::
          {:ok, SessionThread.t() | nil} | {:error, term()}
  def get_primary_thread(%Session{} = session, actor \\ nil, load \\ []) when is_list(load) do
    SessionThread
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(session_id == ^session.id and role == :primary)
    |> maybe_load(load)
    |> Ash.read_one()
  end

  @spec primary_thread_id(String.t()) :: String.t() | nil
  def primary_thread_id(session_id) when is_binary(session_id) do
    SessionThread
    |> Ash.Query.for_read(:read, %{}, domain: Sessions, authorize?: false)
    |> Ash.Query.filter(session_id == ^session_id and role == :primary)
    |> Ash.Query.select([:id])
    |> Ash.read_one!()
    |> case do
      %SessionThread{id: id} -> id
      _other -> nil
    end
  end

  @spec sync_primary_thread(Session.t(), struct() | nil, keyword()) ::
          {:ok, SessionThread.t()} | {:error, term()}
  def sync_primary_thread(%Session{} = session, actor \\ nil, load \\ []) when is_list(load) do
    with {:ok, %SessionThread{} = thread} <- ensure_primary_thread(session, actor, load) do
      update_status(
        thread,
        thread_status(session.status),
        normalize_stop_reason(session.stop_reason),
        actor
      )
    end
  end

  @spec list_threads(Session.t(), struct() | nil, keyword()) ::
          {:ok, [SessionThread.t()]} | {:error, term()}
  def list_threads(%Session{} = session, actor \\ nil, load \\ []) when is_list(load) do
    SessionThread
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(session_id == ^session.id)
    |> Ash.Query.sort(created_at: :asc)
    |> maybe_load(load)
    |> Ash.read()
  end

  @spec get_thread(Session.t(), String.t(), struct() | nil, keyword()) ::
          {:ok, SessionThread.t() | nil} | {:error, term()}
  def get_thread(%Session{} = session, thread_id, actor \\ nil, load \\ [])
      when is_binary(thread_id) and is_list(load) do
    SessionThread
    |> Ash.Query.for_read(:by_id, %{id: thread_id}, ash_opts(actor))
    |> Ash.Query.filter(session_id == ^session.id)
    |> maybe_load(load)
    |> Ash.read_one()
  end

  @spec ensure_delegate_thread(Session.t(), SessionThread.t(), AgentVersion.t(), struct() | nil) ::
          {:ok, {SessionThread.t(), boolean()}} | {:error, term()}
  def ensure_delegate_thread(
        %Session{} = session,
        %SessionThread{} = parent_thread,
        %AgentVersion{} = agent_version,
        actor \\ nil
      ) do
    with {:ok, maybe_thread} <- find_delegate_thread(session, parent_thread, agent_version, actor) do
      case maybe_thread do
        %SessionThread{} = thread ->
          {:ok, {thread, false}}

        nil ->
          create_delegate_thread(session, parent_thread, agent_version, actor)
      end
    end
  end

  @spec update_status(SessionThread.t(), atom(), map() | nil, struct() | nil) ::
          {:ok, SessionThread.t()} | {:error, term()}
  def update_status(%SessionThread{} = thread, status, stop_reason, actor)
      when status in [:idle, :running, :archived] do
    next_stop_reason = normalize_stop_reason(stop_reason)

    if thread.status == status and thread.stop_reason == next_stop_reason do
      {:ok, thread}
    else
      thread
      |> Ash.Changeset.for_update(
        :update,
        %{status: status, stop_reason: next_stop_reason},
        ash_opts(actor)
      )
      |> Ash.update()
    end
  end

  defp create_primary_thread(%Session{} = session, actor, load) do
    SessionThread
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: session.user_id,
        session_id: session.id,
        agent_id: session.agent_id,
        agent_version_id: session.agent_version_id,
        role: :primary,
        status: thread_status(session.status),
        stop_reason: normalize_stop_reason(session.stop_reason),
        metadata: %{"scope" => "primary_thread"}
      },
      ash_opts(actor)
    )
    |> Ash.create(
      upsert?: true,
      upsert_identity: :unique_primary_thread_per_session,
      upsert_fields: [:status, :stop_reason, :metadata],
      touch_update_defaults?: false
    )
    |> case do
      {:ok, %SessionThread{} = thread} ->
        maybe_reload_thread(thread, actor, load)

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_delegate_thread(
         %Session{} = session,
         %SessionThread{} = parent_thread,
         agent_version,
         actor
       ) do
    SessionThread
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(
      session_id == ^session.id and
        parent_thread_id == ^parent_thread.id and
        agent_id == ^agent_version.agent_id and
        role == :delegate
    )
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.read_one()
  end

  defp create_delegate_thread(
         %Session{} = session,
         %SessionThread{} = parent_thread,
         agent_version,
         actor
       ) do
    SessionThread
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: session.user_id,
        session_id: session.id,
        agent_id: agent_version.agent_id,
        agent_version_id: agent_version.id,
        parent_thread_id: parent_thread.id,
        role: :delegate,
        status: :idle,
        metadata: %{"scope" => "delegate_thread"}
      },
      ash_opts(actor)
    )
    |> Ash.create()
    |> case do
      {:ok, %SessionThread{} = thread} -> {:ok, {thread, true}}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_reload_thread(%SessionThread{} = thread, _actor, []), do: {:ok, thread}

  defp maybe_reload_thread(%SessionThread{} = thread, actor, load) do
    SessionThread
    |> Ash.Query.for_read(:by_id, %{id: thread.id}, ash_opts(actor))
    |> Ash.Query.load(load)
    |> Ash.read_one()
  end

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)

  defp thread_status(:running), do: :running
  defp thread_status(:archived), do: :archived
  defp thread_status(:deleted), do: :archived
  defp thread_status(_status), do: :idle

  defp normalize_stop_reason(nil), do: nil
  defp normalize_stop_reason(stop_reason) when is_map(stop_reason), do: stop_reason
  defp normalize_stop_reason(_stop_reason), do: nil

  defp ash_opts(nil), do: [domain: Sessions, authorize?: false]
  defp ash_opts(actor), do: [actor: actor, domain: Sessions]
end
