defmodule JidoManagedAgentsWeb.V1.SessionController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.AshActor
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionDefinition,
    SessionEventDefinition,
    SessionEventLog,
    SessionEvent,
    SessionThread,
    SessionThreadDefinition,
    SessionSkillLimit,
    SessionStream,
    SessionThreads,
    SessionVault,
    Workspace
  }

  alias Plug.Conn

  @session_load [:agent_version, :session_vaults]
  @thread_load [:agent_version]
  @stream_replay_page_size 100
  @stream_check_interval 1_000

  def create(conn, params) do
    with {:ok, payload} <-
           SessionDefinition.normalize_create_payload(params, AshActor.actor(conn)),
         {:ok, %Session{} = session} <- create_session(conn, payload) do
      conn
      |> Conn.put_status(:created)
      |> render_object(SessionDefinition.serialize_session(session))
    end
  end

  def index(conn, _params) do
    query =
      Session
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Sessions))
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(@session_load)

    with {:ok, sessions} <- Ash.read(query) do
      render_list(conn, sessions, &SessionDefinition.serialize_session/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id) do
      render_object(conn, SessionDefinition.serialize_session(session))
    end
  end

  def threads(conn, %{"id" => id}) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, threads} <-
           SessionThreads.list_threads(session, AshActor.actor(conn), @thread_load) do
      render_list(conn, threads, &SessionThreadDefinition.serialize_thread/1)
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id),
         {:ok, %Session{} = archived_session} <- archive_session(conn, session) do
      render_object(conn, SessionDefinition.serialize_session(archived_session))
    end
  end

  def events(conn, %{"id" => id} = params) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, pagination} <- SessionEventDefinition.normalize_list_params(params),
         {:ok, {events, has_more}} <-
           SessionEventLog.list_events(session, pagination, AshActor.actor(conn)) do
      render_list(conn, events, &SessionEventDefinition.serialize_event/1, has_more: has_more)
    end
  end

  def stream(conn, %{"id" => id} = params) do
    actor = AshActor.actor(conn)

    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, stream_params} <- SessionEventDefinition.normalize_stream_params(params),
         :ok <- SessionStream.subscribe(session.id) do
      try do
        conn =
          conn
          |> Conn.put_resp_header("cache-control", "no-cache")
          |> Conn.put_resp_header("x-accel-buffering", "no")
          |> Conn.put_resp_content_type("text/event-stream")
          |> Conn.send_chunked(:ok)

        case replay_persisted_session_events(conn, session, actor, stream_params.after) do
          {:ok, conn, last_sequence} ->
            maybe_stream_live_events(conn, session, actor, last_sequence)

          {:error, :closed, conn} ->
            conn
        end
      after
        SessionStream.unsubscribe(session.id)
      end
    end
  end

  def thread_events(conn, %{"id" => id, "thread_id" => thread_id} = params) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, %SessionThread{} = thread} <- get_thread_record(conn, session, thread_id),
         {:ok, pagination} <- SessionEventDefinition.normalize_list_params(params),
         {:ok, {events, has_more}} <-
           SessionEventLog.list_thread_events(thread, pagination, AshActor.actor(conn)) do
      render_list(conn, events, &SessionEventDefinition.serialize_event/1, has_more: has_more)
    end
  end

  def thread_stream(conn, %{"id" => id, "thread_id" => thread_id} = params) do
    actor = AshActor.actor(conn)

    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, %SessionThread{} = thread} <- get_thread_record(conn, session, thread_id),
         {:ok, stream_params} <- SessionEventDefinition.normalize_stream_params(params),
         :ok <- SessionStream.subscribe_thread(session.id, thread.id) do
      try do
        conn =
          conn
          |> Conn.put_resp_header("cache-control", "no-cache")
          |> Conn.put_resp_header("x-accel-buffering", "no")
          |> Conn.put_resp_content_type("text/event-stream")
          |> Conn.send_chunked(:ok)

        case replay_persisted_thread_events(conn, thread, actor, stream_params.after) do
          {:ok, conn, last_sequence} ->
            stream_live_thread_events(conn, session, thread, actor, last_sequence)

          {:error, :closed, conn} ->
            conn
        end
      after
        SessionStream.unsubscribe_thread(session.id, thread.id)
      end
    end
  end

  def create_event(conn, %{"id" => id} = params) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         {:ok, events} <-
           SessionEventDefinition.normalize_append_payload(params, session, AshActor.actor(conn)),
         {:ok, appended_events} <-
           SessionEventLog.append_user_events(session, events, AshActor.actor(conn)) do
      conn
      |> Conn.put_status(:created)
      |> render_list(appended_events, &SessionEventDefinition.serialize_event/1)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Session{} = session} <- get_session_record(conn, id, []),
         :ok <- soft_delete_session(conn, session) do
      Conn.send_resp(conn, :no_content, "")
    end
  end

  defp get_session_record(conn, id, load \\ @session_load) do
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(conn, domain: Sessions))
      |> maybe_load(load)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Session{} = session} -> {:ok, session}
      {:error, error} -> {:error, error}
    end
  end

  defp get_thread_record(conn, %Session{} = session, thread_id, load \\ []) do
    case SessionThreads.get_thread(session, thread_id, AshActor.actor(conn), load) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %SessionThread{} = thread} -> {:ok, thread}
      {:error, error} -> {:error, error}
    end
  end

  defp create_session(conn, %{agent: %Agent{} = agent, session: attrs}) do
    opts = ash_opts(conn, domain: Sessions)
    resources = [Workspace, Session, SessionVault]

    with :ok <- validate_skill_limit(conn, attrs) do
      Ash.transact(resources, fn ->
        with {:ok, %Workspace{} = workspace} <- resolve_or_create_workspace(conn, agent),
             {:ok, %Session{} = session} <- create_session_record(attrs, workspace, opts),
             {:ok, %Session{} = loaded_session} <- load_session(session.id, opts) do
          loaded_session
        end
      end)
    end
    |> map_create_session_error()
  end

  defp resolve_or_create_workspace(conn, %Agent{} = agent) do
    actor = AshActor.actor(conn)

    query =
      Workspace
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Sessions))
      |> Ash.Query.filter(user_id == ^actor.id and agent_id == ^agent.id)

    case Ash.read_one(query) do
      {:ok, %Workspace{} = workspace} ->
        {:ok, workspace}

      {:ok, nil} ->
        create_default_workspace(conn, agent)

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_default_workspace(conn, %Agent{} = agent) do
    actor = AshActor.actor(conn)
    opts = ash_opts(conn, domain: Sessions)

    Workspace
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: actor.id,
        agent_id: agent.id,
        name: "#{agent.name} workspace"
      },
      opts
    )
    |> Ash.create(
      upsert?: true,
      upsert_identity: :unique_workspace_per_user_agent,
      upsert_fields: [],
      touch_update_defaults?: false
    )
  end

  defp create_session_record(attrs, %Workspace{} = workspace, opts) do
    Session
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :workspace_id, workspace.id), opts)
    |> Ash.create()
  end

  defp load_session(session_id, opts) do
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: session_id}, opts)
      |> Ash.Query.load(@session_load)

    case Ash.read_one(query) do
      {:ok, %Session{} = session} -> {:ok, session}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp archive_session(_conn, %Session{archived_at: %DateTime{}} = session), do: {:ok, session}

  defp archive_session(conn, %Session{} = session) do
    opts = ash_opts(conn, domain: Sessions)

    with {:ok, %Session{} = archived_session} <-
           session
           |> Ash.Changeset.for_update(:archive, %{}, opts)
           |> Ash.update() do
      load_session(archived_session.id, opts)
    end
  end

  defp soft_delete_session(conn, %Session{} = session) do
    case session
         |> Ash.Changeset.for_destroy(:soft_delete, %{}, ash_opts(conn, domain: Sessions))
         |> Ash.destroy(return_destroyed?: true) do
      :ok -> :ok
      {:ok, _deleted_session} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp map_create_session_error({:error, %Ash.Error.Invalid{} = error}) do
    if Exception.message(error) =~ "workspace already has an active session" do
      {:error, {:conflict, "workspace already has an active session"}}
    else
      {:error, error}
    end
  end

  defp map_create_session_error(result), do: result

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)

  defp validate_skill_limit(conn, attrs) do
    SessionSkillLimit.validate(Map.get(attrs, :agent_version_id), AshActor.actor(conn))
  end

  defp replay_persisted_session_events(conn, session, actor, after_sequence) do
    case SessionEventLog.list_events(
           session,
           %{limit: @stream_replay_page_size, after: after_sequence},
           actor
         ) do
      {:ok, {events, has_more}} ->
        visible_events = Enum.filter(events, &SessionStream.session_event_visible?/1)
        replay_sequence = last_replayed_sequence(events, after_sequence)

        with {:ok, conn, _last_visible_sequence} <-
               chunk_events(conn, visible_events, after_sequence) do
          if has_more do
            replay_persisted_session_events(conn, session, actor, replay_sequence)
          else
            {:ok, conn, replay_sequence}
          end
        end

      {:error, error} ->
        raise error
    end
  end

  defp replay_persisted_thread_events(conn, %SessionThread{} = thread, actor, after_sequence) do
    case SessionEventLog.list_thread_events(
           thread,
           %{limit: @stream_replay_page_size, after: after_sequence},
           actor
         ) do
      {:ok, {events, has_more}} ->
        with {:ok, conn, last_sequence} <- chunk_events(conn, events, after_sequence) do
          if has_more do
            replay_persisted_thread_events(conn, thread, actor, last_sequence)
          else
            {:ok, conn, last_sequence}
          end
        end

      {:error, error} ->
        raise error
    end
  end

  defp maybe_stream_live_events(conn, %Session{} = session, actor, last_sequence) do
    if session.status in [:idle, :running] do
      stream_live_events(conn, session.id, actor, last_sequence)
    else
      conn
    end
  end

  defp stream_live_events(conn, session_id, actor, last_sequence) do
    receive do
      {:session_event, %SessionEvent{session_id: ^session_id, sequence: sequence} = event}
      when sequence > last_sequence ->
        case chunk_event(conn, event) do
          {:ok, conn} -> stream_live_events(conn, session_id, actor, sequence)
          {:error, :closed, conn} -> conn
        end

      {:session_event, %SessionEvent{session_id: ^session_id}} ->
        stream_live_events(conn, session_id, actor, last_sequence)

      {:session_closed, %{session_id: ^session_id}} ->
        conn

      _other ->
        stream_live_events(conn, session_id, actor, last_sequence)
    after
      @stream_check_interval ->
        if session_open?(session_id, actor) do
          stream_live_events(conn, session_id, actor, last_sequence)
        else
          conn
        end
    end
  end

  defp stream_live_thread_events(
         conn,
         %Session{} = session,
         %SessionThread{} = thread,
         actor,
         last_sequence
       ) do
    receive do
      {:thread_event,
       %SessionEvent{
         session_id: session_id,
         session_thread_id: session_thread_id,
         sequence: sequence
       } = event}
      when session_id == session.id and session_thread_id == thread.id and
             sequence > last_sequence ->
        case chunk_event(conn, event) do
          {:ok, conn} -> stream_live_thread_events(conn, session, thread, actor, sequence)
          {:error, :closed, conn} -> conn
        end

      {:thread_event, %SessionEvent{session_id: session_id, session_thread_id: session_thread_id}}
      when session_id == session.id and session_thread_id == thread.id ->
        stream_live_thread_events(conn, session, thread, actor, last_sequence)

      {:session_closed, %{session_id: session_id}} when session_id == session.id ->
        conn

      _other ->
        stream_live_thread_events(conn, session, thread, actor, last_sequence)
    after
      @stream_check_interval ->
        if session_open?(session.id, actor) do
          stream_live_thread_events(conn, session, thread, actor, last_sequence)
        else
          conn
        end
    end
  end

  defp chunk_events(conn, [], last_sequence), do: {:ok, conn, last_sequence}

  defp chunk_events(conn, events, _last_sequence) do
    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, conn} ->
      case chunk_event(conn, event) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, :closed, conn} -> {:halt, {:error, :closed, conn}}
      end
    end)
    |> case do
      {:ok, conn} ->
        {:ok, conn, events |> List.last() |> Map.fetch!(:sequence)}

      {:error, :closed, conn} ->
        {:error, :closed, conn}
    end
  end

  defp chunk_event(conn, %SessionEvent{} = event) do
    payload =
      event
      |> SessionEventDefinition.serialize_event()
      |> Jason.encode_to_iodata!()

    case Conn.chunk(conn, ["data: ", payload, "\n\n"]) do
      {:ok, conn} -> {:ok, conn}
      {:error, :closed} -> {:error, :closed, conn}
    end
  end

  defp last_replayed_sequence([], after_sequence), do: after_sequence

  defp last_replayed_sequence(events, _after_sequence),
    do: events |> List.last() |> Map.fetch!(:sequence)

  defp session_open?(session_id, actor) do
    query =
      Ash.Query.for_read(Session, :by_id, %{id: session_id}, ash_opts(actor, domain: Sessions))

    case Ash.read_one(query) do
      {:ok, %Session{status: status}} when status in [:idle, :running] -> true
      {:ok, _session} -> false
      {:error, _error} -> false
    end
  end
end
