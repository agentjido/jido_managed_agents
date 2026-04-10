defmodule JidoManagedAgentsWeb.SessionObservabilityLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventDefinition,
    SessionEventLog,
    SessionRuntime,
    SessionThread
  }

  alias JidoManagedAgentsWeb.ConsoleHelpers

  @detail_event_limit 250
  @tool_use_event_types ["agent.tool_use", "agent.mcp_tool_use", "agent.custom_tool_use"]
  @tool_result_event_types ["agent.tool_result", "agent.mcp_tool_result"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:page_title, "Sessions")
     |> assign(:sessions, [])
     |> assign_detail(nil, nil)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    actor = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:page_title, "Sessions")
     |> assign(:sessions, list_sessions(actor))
     |> assign_detail(nil, nil)}
  end

  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :show}} = socket) do
    actor = socket.assigns.current_user
    selected_thread_id = Map.get(params, "thread_id")

    case load_detail(id, selected_thread_id, actor) do
      {:ok, detail} ->
        {:noreply,
         socket
         |> assign(:page_title, detail_title(detail.session))
         |> assign(:sessions, [])
         |> assign_detail(detail, selected_thread_id)}

      {:error, :invalid_thread} ->
        {:noreply,
         socket
         |> put_flash(:error, "The requested thread trace was not found for this session.")
         |> push_patch(to: ~p"/console/sessions/#{id}")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Session not found.")
         |> push_navigate(to: ~p"/console/sessions")}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, ConsoleHelpers.error_message(error))
         |> push_navigate(to: ~p"/console/sessions")}
    end
  end

  @impl true
  def handle_event(
        "confirm_tool",
        %{"result" => result, "tool_use_id" => tool_use_id},
        %{assigns: %{session: %Session{} = session}} = socket
      ) do
    actor = socket.assigns.current_user

    case submit_tool_confirmation(
           session,
           tool_use_id,
           result,
           socket.assigns.selected_thread_id,
           actor
         ) do
      {:ok, refreshed_detail} ->
        {:noreply,
         socket
         |> put_flash(:info, confirmation_message(result))
         |> assign(:page_title, detail_title(refreshed_detail.session))
         |> assign_detail(refreshed_detail, socket.assigns.selected_thread_id)}

      {:error, error} ->
        case load_detail(session.id, socket.assigns.selected_thread_id, actor) do
          {:ok, refreshed_detail} ->
            {:noreply,
             socket
             |> put_flash(:error, ConsoleHelpers.error_message(error))
             |> assign_detail(refreshed_detail, socket.assigns.selected_thread_id)}

          _other ->
            {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
        end
    end
  end

  def handle_event("confirm_tool", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      main_class="px-4 py-8 sm:px-6 lg:px-8"
      container_class="mx-auto max-w-7xl space-y-8"
    >
      <%= if @live_action == :index do %>
        <section class="overflow-hidden rounded-[2rem] border border-amber-200/70 bg-[radial-gradient(circle_at_top_left,_rgba(245,158,11,0.18),_transparent_38%),linear-gradient(135deg,_#111827,_#172554_58%,_#1f2937)] text-white shadow-2xl shadow-amber-950/20">
          <div class="grid gap-8 px-6 py-8 lg:grid-cols-[minmax(0,1.18fr)_minmax(0,0.82fr)] lg:px-10">
            <div class="space-y-4">
              <p class="text-xs font-semibold uppercase tracking-[0.28em] text-amber-200">
                Session Observability
              </p>
              <h1 class="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
                Sessions
              </h1>
              <p class="max-w-2xl text-sm leading-6 text-amber-50/80">
                Inspect recent runs without leaving the dashboard. Trace the exact event stream, provider usage, tool activity, and any blocked approvals before you touch the database.
              </p>
              <div class="flex flex-wrap gap-3 pt-2">
                <.console_tab navigate={~p"/console/agents/new"} label="Agents" />
                <.console_tab navigate={~p"/console/environments"} label="Environments" />
                <.console_tab navigate={~p"/console/vaults"} label="Vaults" />
                <.console_tab navigate={nil} label="Sessions" />
              </div>
            </div>
            <div class="grid gap-4 rounded-[1.5rem] border border-white/10 bg-white/5 p-5 text-sm text-amber-50/90 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
              <.metric_card label="Sessions" value={length(@sessions)} />
              <.metric_card label="Running" value={count_sessions(@sessions, "running")} />
              <.metric_card label="Needs Input" value={count_requires_action(@sessions)} />
            </div>
          </div>
        </section>

        <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-amber-700">
                Session List
              </p>
              <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                Recent traces
              </h2>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                Status, model selection, and agent ownership stay visible at a glance so you can jump straight to the session that needs attention.
              </p>
            </div>
          </div>

          <div
            :if={@sessions == []}
            class="mt-6 rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-5 py-10 text-center text-sm text-neutral-500"
          >
            No sessions yet. Launch a run from the agent builder to start collecting traces.
          </div>

          <div :if={@sessions != []} id="session-list" class="mt-6 space-y-4">
            <.link
              :for={session <- @sessions}
              id={"session-card-#{session.id}"}
              navigate={~p"/console/sessions/#{session.id}"}
              class="block rounded-[1.5rem] border border-neutral-200 bg-neutral-50/80 p-5 transition hover:border-amber-300 hover:bg-amber-50/60"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div class="space-y-3">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-base font-semibold text-neutral-950">
                      {session.title || short_id(session.id)}
                    </p>
                    <span class={status_badge_class(session.status)}>
                      {status_label(session.status)}
                    </span>
                    <span
                      :if={requires_action?(session.stop_reason)}
                      class="inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-amber-900"
                    >
                      Needs input
                    </span>
                  </div>
                  <div class="grid gap-3 text-sm text-neutral-600 sm:grid-cols-2 xl:grid-cols-4">
                    <p>
                      <span class="font-medium text-neutral-900">Agent:</span>
                      {session_agent_name(session)}
                    </p>
                    <p>
                      <span class="font-medium text-neutral-900">Model:</span>
                      {session_model(session)}
                    </p>
                    <p>
                      <span class="font-medium text-neutral-900">Created:</span>
                      {ConsoleHelpers.format_timestamp(session.created_at)}
                    </p>
                    <p>
                      <span class="font-medium text-neutral-900">Trace:</span>
                      {thread_summary(session)}
                    </p>
                  </div>
                </div>
                <div class="inline-flex items-center gap-2 rounded-full border border-neutral-200 bg-white px-4 py-2 text-sm font-medium text-neutral-700">
                  Inspect <.icon name="hero-arrow-right" class="size-4" />
                </div>
              </div>
            </.link>
          </div>
        </section>
      <% else %>
        <section
          id="session-detail"
          class="overflow-hidden rounded-[2rem] border border-cyan-200/70 bg-[radial-gradient(circle_at_top_left,_rgba(34,211,238,0.18),_transparent_40%),linear-gradient(135deg,_#082f49,_#0f172a_56%,_#164e63)] text-white shadow-2xl shadow-cyan-950/20"
        >
          <div class="grid gap-8 px-6 py-8 lg:grid-cols-[minmax(0,1.12fr)_minmax(0,0.88fr)] lg:px-10">
            <div class="space-y-4">
              <div class="flex flex-wrap items-center gap-3">
                <.link
                  navigate={~p"/console/sessions"}
                  class="inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/10 px-4 py-2 text-sm font-medium text-cyan-50 transition hover:bg-white/15"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> Session list
                </.link>
                <span class={detail_status_badge_class(@session.status)}>
                  {status_label(@session.status)}
                </span>
                <span
                  :if={@pending_confirmations != []}
                  class="inline-flex items-center rounded-full bg-amber-300/90 px-3 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.2em] text-amber-950"
                >
                  Awaiting approval
                </span>
              </div>
              <p class="text-xs font-semibold uppercase tracking-[0.28em] text-cyan-200">
                Trace Detail
              </p>
              <h1 class="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
                {detail_title(@session)}
              </h1>
              <p class="max-w-2xl text-sm leading-6 text-cyan-50/80">
                Agent <span class="font-medium text-white">{session_agent_name(@session)}</span>
                on model <span class="font-medium text-white">{session_model(@session)}</span>.
                Created {ConsoleHelpers.format_timestamp(@session.created_at)}.
              </p>
              <div class="flex flex-wrap gap-3 pt-2 text-sm text-cyan-50/85">
                <span class="rounded-full border border-white/10 bg-white/5 px-3 py-1.5">
                  Trace scope: {@selected_trace_label}
                </span>
                <span class="rounded-full border border-white/10 bg-white/5 px-3 py-1.5">
                  Events: {length(@display_events)}
                </span>
                <span class="rounded-full border border-white/10 bg-white/5 px-3 py-1.5">
                  Threads: {length(@threads)}
                </span>
              </div>
            </div>
            <div class="grid gap-4 rounded-[1.5rem] border border-white/10 bg-white/5 p-5 text-sm text-cyan-50/90 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
              <%= if @metrics do %>
                <.metric_card label="Input Tokens" value={format_metric(@metrics["input_tokens"])} />
                <.metric_card
                  label="Output Tokens"
                  value={format_metric(@metrics["output_tokens"])}
                />
                <.metric_card label="Total Tokens" value={format_metric(@metrics["total_tokens"])} />
              <% else %>
                <.metric_card label="Input Tokens" value="Unavailable" />
                <.metric_card label="Output Tokens" value="Unavailable" />
                <.metric_card label="Total Tokens" value="Unavailable" />
              <% end %>
            </div>
          </div>
        </section>

        <section
          id="thread-traces"
          class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-cyan-700">
                Trace Scope
              </p>
              <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                Thread traces
              </h2>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                Start with the aggregated session trace, then drill into one thread at a time when delegation is active.
              </p>
            </div>
          </div>

          <div class="mt-6 flex flex-wrap gap-3">
            <.trace_scope_button
              id="trace-scope-all"
              patch={trace_scope_path(@session, nil)}
              active={is_nil(@selected_thread)}
              label="All traces"
            />
            <.trace_scope_button
              :for={thread <- @threads}
              id={"trace-scope-thread-#{thread.id}"}
              patch={trace_scope_path(@session, thread)}
              active={selected_thread?(@selected_thread, thread)}
              label={thread_scope_label(thread)}
            />
          </div>
        </section>

        <div class="grid gap-8 xl:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)]">
          <div class="space-y-8">
            <section
              id="session-trace"
              class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.24em] text-cyan-700">
                    Trace Timeline
                  </p>
                  <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                    Chronological events
                  </h2>
                  <p class="mt-1 text-sm leading-6 text-neutral-600">
                    Ordered event flow across status changes, agent messages, tools, approvals, and thread hand-offs.
                  </p>
                </div>
              </div>

              <div
                :if={@latest_error_event}
                class="mt-6 rounded-[1.5rem] border border-rose-200 bg-rose-50 px-5 py-4 text-sm text-rose-900"
              >
                <p class="font-semibold">Latest error</p>
                <p class="mt-2 leading-6">{timeline_summary(@latest_error_event)}</p>
              </div>

              <div class="mt-6 space-y-4">
                <div
                  :for={event <- @display_events}
                  id={"timeline-event-#{event.id}"}
                  class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-5"
                >
                  <div class="flex flex-wrap items-start justify-between gap-4">
                    <div class="space-y-3">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="inline-flex items-center rounded-full bg-neutral-900 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-white">
                          #{event.sequence}
                        </span>
                        <span class={event_badge_class(event.type)}>
                          {event.type}
                        </span>
                        <span class="inline-flex items-center rounded-full bg-white px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-neutral-500">
                          {event_thread_label(event, @thread_labels)}
                        </span>
                      </div>
                      <p class="text-sm leading-6 text-neutral-800">
                        {timeline_summary(event)}
                      </p>
                    </div>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      {event_timestamp(event)}
                    </p>
                  </div>
                </div>
              </div>
            </section>

            <section
              id="session-tool-executions"
              class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.24em] text-cyan-700">
                    Tool Execution
                  </p>
                  <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                    Inputs and results
                  </h2>
                  <p class="mt-1 text-sm leading-6 text-neutral-600">
                    Every tool invocation stays paired with its input, confirmation state, and final result payload when available.
                  </p>
                </div>
              </div>

              <div
                :if={@tool_entries == []}
                class="mt-6 rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-5 py-10 text-center text-sm text-neutral-500"
              >
                No tool executions were recorded for the current trace scope.
              </div>

              <div :if={@tool_entries != []} class="mt-6 space-y-5">
                <div
                  :for={entry <- @tool_entries}
                  id={"tool-entry-#{entry.use_event.id}"}
                  class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-5"
                >
                  <div class="flex flex-wrap items-start justify-between gap-4">
                    <div class="space-y-2">
                      <div class="flex flex-wrap items-center gap-2">
                        <p class="text-base font-semibold text-neutral-950">{entry.tool_name}</p>
                        <span class={tool_kind_badge_class(entry.kind)}>
                          {tool_kind_label(entry.kind)}
                        </span>
                        <span class={tool_status_badge_class(entry.status)}>
                          {tool_status_label(entry.status)}
                        </span>
                      </div>
                      <p class="text-sm leading-6 text-neutral-600">
                        {tool_entry_summary(entry)}
                      </p>
                    </div>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      Event #{entry.use_event.sequence}
                    </p>
                  </div>

                  <div
                    :if={entry.awaiting_confirmation?}
                    id={"pending-confirmation-#{entry.use_event.id}"}
                    class="mt-5 rounded-[1.25rem] border border-amber-200 bg-amber-50 p-4"
                  >
                    <div class="flex flex-wrap items-start justify-between gap-4">
                      <div>
                        <p class="text-sm font-semibold text-amber-950">
                          Approval required
                        </p>
                        <p class="mt-1 text-sm leading-6 text-amber-900/80">
                          This session is paused until a `user.tool_confirmation` event allows or denies the request.
                        </p>
                      </div>
                      <div class="flex flex-wrap gap-3">
                        <.button
                          id={"confirm-allow-#{entry.use_event.id}"}
                          phx-click="confirm_tool"
                          phx-value-tool_use_id={entry.use_event.id}
                          phx-value-result="allow"
                          class="rounded-full bg-emerald-600 px-5 text-white hover:bg-emerald-500"
                        >
                          Allow
                        </.button>
                        <.button
                          id={"confirm-deny-#{entry.use_event.id}"}
                          phx-click="confirm_tool"
                          phx-value-tool_use_id={entry.use_event.id}
                          phx-value-result="deny"
                          class="rounded-full border border-rose-300 bg-white px-5 text-rose-700 hover:border-rose-400 hover:bg-rose-50"
                        >
                          Deny
                        </.button>
                      </div>
                    </div>
                  </div>

                  <div class="mt-5 grid gap-4 lg:grid-cols-2">
                    <div class="rounded-[1.25rem] border border-neutral-200 bg-white p-4">
                      <p class="text-xs font-semibold uppercase tracking-[0.2em] text-neutral-500">
                        Input
                      </p>
                      <pre class="mt-3 overflow-x-auto text-xs leading-6 text-neutral-800">{entry.input_json}</pre>
                    </div>
                    <div class="rounded-[1.25rem] border border-neutral-200 bg-white p-4">
                      <p class="text-xs font-semibold uppercase tracking-[0.2em] text-neutral-500">
                        Outcome
                      </p>
                      <pre class="mt-3 overflow-x-auto text-xs leading-6 text-neutral-800">{entry.outcome_json}</pre>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div class="space-y-8">
            <section
              id="session-metrics"
              class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm"
            >
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-cyan-700">
                  Provider Metrics
                </p>
                <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                  Usage snapshot
                </h2>
                <p class="mt-1 text-sm leading-6 text-neutral-600">
                  Token or provider usage is aggregated from recorded event payloads when the runtime supplies it.
                </p>
              </div>

              <%= if @metrics do %>
                <div class="mt-6 grid gap-4 sm:grid-cols-2">
                  <div
                    :for={{metric, value} <- metric_entries(@metrics)}
                    class="rounded-[1.25rem] border border-neutral-200 bg-neutral-50 p-4"
                  >
                    <p class="text-xs font-semibold uppercase tracking-[0.2em] text-neutral-500">
                      {metric}
                    </p>
                    <p class="mt-3 text-2xl font-semibold tracking-tight text-neutral-950">
                      {value}
                    </p>
                  </div>
                </div>
              <% else %>
                <div class="mt-6 rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-5 py-10 text-center text-sm text-neutral-500">
                  No provider metrics were recorded for this trace yet.
                </div>
              <% end %>
            </section>

            <section
              id="session-raw-events"
              class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm"
            >
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-cyan-700">
                  Raw Events
                </p>
                <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                  Persisted payloads
                </h2>
                <p class="mt-1 text-sm leading-6 text-neutral-600">
                  Directly inspect the stored event shape, including payload, stop reason, and thread identifiers.
                </p>
              </div>

              <div class="mt-6 space-y-4">
                <div
                  :for={event <- @display_events}
                  id={"raw-event-#{event.id}"}
                  class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4"
                >
                  <div class="flex flex-wrap items-center justify-between gap-3">
                    <p class="text-sm font-semibold text-neutral-950">
                      #{event.sequence} · {event.type}
                    </p>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      {event_timestamp(event)}
                    </p>
                  </div>
                  <pre class="mt-4 overflow-x-auto text-xs leading-6 text-neutral-800">{pretty_event(event)}</pre>
                </div>
              </div>
            </section>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp load_detail(session_id, selected_thread_id, actor) do
    with {:ok, %Session{} = session} <- fetch_session(session_id, actor),
         {:ok, selected_thread} <- resolve_selected_thread(session, selected_thread_id),
         {:ok, events} <- load_detail_events(session, selected_thread, actor) do
      threads = sort_threads(session.threads || [])

      {:ok,
       %{
         session: session,
         threads: threads,
         selected_thread: selected_thread,
         display_events: events,
         tool_entries: tool_entries(events, session.stop_reason),
         pending_confirmations: pending_confirmation_events(events, session.stop_reason),
         metrics: aggregate_metrics(events),
         latest_error_event: latest_error_event(events),
         thread_labels: thread_labels(threads),
         selected_trace_label: selected_trace_label(selected_thread, threads)
       }}
    end
  end

  defp submit_tool_confirmation(
         %Session{} = session,
         tool_use_id,
         result,
         selected_thread_id,
         actor
       ) do
    params = %{
      "type" => "user.tool_confirmation",
      "tool_use_id" => tool_use_id,
      "result" => result
    }

    with {:ok, events} <- SessionEventDefinition.normalize_append_payload(params, session, actor),
         {:ok, _appended_events} <- SessionEventLog.append_user_events(session, events, actor),
         {:ok, _run_result} <- safe_run_session(session.id, actor),
         {:ok, detail} <- load_detail(session.id, selected_thread_id, actor) do
      {:ok, detail}
    end
  end

  defp safe_run_session(session_id, actor) do
    try do
      SessionRuntime.run(session_id, actor)
    rescue
      error -> {:error, error}
    end
  end

  defp fetch_session(id, actor) do
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Sessions)
      |> Ash.Query.load([:agent, :agent_version, threads: [:agent, :agent_version]])

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Session{} = session} -> {:ok, session}
      {:error, error} -> {:error, error}
    end
  end

  defp load_detail_events(%Session{} = session, nil, actor) do
    SessionEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> Ash.Query.filter(session_id == ^session.id)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(@detail_event_limit)
    |> Ash.read()
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, error} -> {:error, error}
    end
  end

  defp load_detail_events(%Session{} = session, %SessionThread{} = selected_thread, actor) do
    SessionEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> Ash.Query.filter(session_id == ^session.id and session_thread_id == ^selected_thread.id)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(@detail_event_limit)
    |> Ash.read()
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_selected_thread(_session, nil), do: {:ok, nil}

  defp resolve_selected_thread(%Session{threads: threads}, selected_thread_id) do
    case Enum.find(threads || [], &(&1.id == selected_thread_id)) do
      %SessionThread{} = thread -> {:ok, thread}
      nil -> {:error, :invalid_thread}
    end
  end

  defp list_sessions(actor) do
    Session
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.load([:agent, :agent_version])
    |> Ash.read!()
  end

  defp assign_detail(socket, nil, selected_thread_id) do
    socket
    |> assign(:session, nil)
    |> assign(:threads, [])
    |> assign(:selected_thread, nil)
    |> assign(:selected_thread_id, selected_thread_id)
    |> assign(:display_events, [])
    |> assign(:tool_entries, [])
    |> assign(:pending_confirmations, [])
    |> assign(:metrics, nil)
    |> assign(:latest_error_event, nil)
    |> assign(:thread_labels, %{})
    |> assign(:selected_trace_label, "All traces")
  end

  defp assign_detail(socket, detail, selected_thread_id) when is_map(detail) do
    socket
    |> assign(:session, detail.session)
    |> assign(:threads, detail.threads)
    |> assign(:selected_thread, detail.selected_thread)
    |> assign(:selected_thread_id, selected_thread_id)
    |> assign(:display_events, detail.display_events)
    |> assign(:tool_entries, detail.tool_entries)
    |> assign(:pending_confirmations, detail.pending_confirmations)
    |> assign(:metrics, detail.metrics)
    |> assign(:latest_error_event, detail.latest_error_event)
    |> assign(:thread_labels, detail.thread_labels)
    |> assign(:selected_trace_label, detail.selected_trace_label)
  end

  defp sort_threads(threads) do
    Enum.sort_by(List.wrap(threads), fn thread ->
      {thread_sort_rank(thread.role), thread.created_at || DateTime.from_unix!(0)}
    end)
  end

  defp thread_sort_rank(:primary), do: 0
  defp thread_sort_rank(_role), do: 1

  defp thread_labels(threads) do
    Map.new(threads, fn thread -> {thread.id, thread_scope_label(thread)} end)
  end

  defp selected_trace_label(nil, threads) do
    if length(threads) > 1, do: "All threads", else: "Primary thread"
  end

  defp selected_trace_label(%SessionThread{} = thread, _threads), do: thread_scope_label(thread)

  defp pending_confirmation_events(events, stop_reason) do
    event_ids = requires_action_event_ids(stop_reason)
    event_map = Map.new(events, &{&1.id, &1})

    event_ids
    |> Enum.map(&Map.get(event_map, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&awaiting_confirmation_event?/1)
  end

  defp awaiting_confirmation_event?(%SessionEvent{} = event) do
    event.type in ["agent.tool_use", "agent.mcp_tool_use"] and
      truthy?(payload_value(event.payload, "awaiting_confirmation"))
  end

  defp aggregate_metrics(events) do
    metrics =
      events
      |> Enum.map(&payload_usage/1)
      |> Enum.filter(&(is_map(&1) and map_size(&1) > 0))
      |> Enum.reduce(%{}, &merge_metrics/2)

    if map_size(metrics) == 0, do: nil, else: metrics
  end

  defp payload_usage(%SessionEvent{payload: payload}) when is_map(payload) do
    case payload_value(payload, "usage") do
      usage when is_map(usage) -> usage
      _other -> %{}
    end
  end

  defp payload_usage(_event), do: %{}

  defp merge_metrics(usage, acc) do
    Enum.reduce(usage, acc, fn {key, value}, metrics ->
      if is_integer(value) do
        Map.update(metrics, to_string(key), value, &(&1 + value))
      else
        metrics
      end
    end)
  end

  defp metric_entries(metrics) do
    preferred = [
      {"Input Tokens", Map.get(metrics, "input_tokens")},
      {"Output Tokens", Map.get(metrics, "output_tokens")},
      {"Total Tokens", Map.get(metrics, "total_tokens")},
      {"Cached Tokens", Map.get(metrics, "cached_tokens")},
      {"Reasoning Tokens", Map.get(metrics, "reasoning_tokens")}
    ]

    preferred
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map(fn {label, value} -> {label, format_metric(value)} end)
  end

  defp latest_error_event(events) do
    Enum.find(Enum.reverse(events), &(&1.type == "session.error"))
  end

  defp tool_entries(events, stop_reason) do
    result_events = tool_result_events(events)
    confirmation_events = confirmation_events(events)
    custom_result_events = custom_result_events(events)
    pending_ids = requires_action_event_ids(stop_reason)

    events
    |> Enum.filter(&(&1.type in @tool_use_event_types))
    |> Enum.map(fn use_event ->
      provider_tool_use_id = payload_value(use_event.payload, "tool_use_id")
      result_event = Map.get(result_events, provider_tool_use_id)
      confirmation = confirmation_for(use_event, provider_tool_use_id, confirmation_events)
      custom_result_event = Map.get(custom_result_events, use_event.id)

      awaiting_confirmation? =
        use_event.id in pending_ids and awaiting_confirmation_event?(use_event)

      awaiting_custom_result? =
        use_event.id in pending_ids and use_event.type == "agent.custom_tool_use"

      %{
        kind: tool_kind(use_event.type),
        status:
          tool_status(
            result_event,
            custom_result_event,
            awaiting_confirmation?,
            awaiting_custom_result?
          ),
        tool_name: payload_value(use_event.payload, "tool_name") || "tool",
        use_event: use_event,
        result_event: result_event,
        confirmation: confirmation,
        custom_result_event: custom_result_event,
        awaiting_confirmation?: awaiting_confirmation?,
        input_json: pretty_data(payload_value(use_event.payload, "input")),
        outcome_json:
          outcome_json(result_event, custom_result_event, confirmation, awaiting_confirmation?)
      }
    end)
  end

  defp tool_result_events(events) do
    events
    |> Enum.filter(&(&1.type in @tool_result_event_types))
    |> Map.new(fn event -> {payload_value(event.payload, "tool_use_id"), event} end)
  end

  defp confirmation_events(events) do
    events
    |> Enum.filter(&(&1.type == "user.tool_confirmation"))
    |> Enum.group_by(&payload_value(&1.payload, "tool_use_id"))
  end

  defp custom_result_events(events) do
    events
    |> Enum.filter(&(&1.type == "user.custom_tool_result"))
    |> Enum.group_by(&payload_value(&1.payload, "custom_tool_use_id"))
    |> Map.new(fn {key, value} -> {key, List.last(value)} end)
  end

  defp confirmation_for(use_event, provider_tool_use_id, confirmation_events) do
    (Map.get(confirmation_events, use_event.id, []) ++
       Map.get(confirmation_events, provider_tool_use_id, []))
    |> List.last()
  end

  defp tool_kind("agent.mcp_tool_use"), do: :mcp
  defp tool_kind("agent.custom_tool_use"), do: :custom
  defp tool_kind(_type), do: :builtin

  defp tool_status(
         result_event,
         _custom_result_event,
         _awaiting_confirmation?,
         _awaiting_custom_result?
       )
       when is_struct(result_event, SessionEvent) do
    if truthy?(payload_value(result_event.payload, "ok")), do: :completed, else: :errored
  end

  defp tool_status(
         _result_event,
         %SessionEvent{},
         _awaiting_confirmation?,
         _awaiting_custom_result?
       ),
       do: :resolved

  defp tool_status(_result_event, _custom_result_event, true, _awaiting_custom_result?),
    do: :awaiting_confirmation

  defp tool_status(_result_event, _custom_result_event, _awaiting_confirmation?, true),
    do: :awaiting_result

  defp tool_status(
         _result_event,
         _custom_result_event,
         _awaiting_confirmation?,
         _awaiting_custom_result?
       ),
       do: :started

  defp outcome_json(result_event, _custom_result_event, _confirmation, false)
       when is_struct(result_event, SessionEvent) do
    result_payload = payload_value(result_event.payload, "result")
    error_payload = payload_value(result_event.payload, "error")

    cond do
      is_map(result_payload) and map_size(result_payload) > 0 -> pretty_data(result_payload)
      is_map(error_payload) and map_size(error_payload) > 0 -> pretty_data(error_payload)
      true -> pretty_data(result_event.payload)
    end
  end

  defp outcome_json(_result_event, %SessionEvent{} = custom_result_event, _confirmation, false) do
    custom_result_event.content
    |> text_content()
    |> case do
      "" -> pretty_data(custom_result_event.payload)
      content -> content
    end
  end

  defp outcome_json(_result_event, _custom_result_event, %SessionEvent{} = confirmation, false) do
    pretty_data(confirmation.payload)
  end

  defp outcome_json(_result_event, _custom_result_event, _confirmation, true),
    do: "Waiting for `user.tool_confirmation`."

  defp outcome_json(_result_event, _custom_result_event, _confirmation, false), do: "(pending)"

  defp requires_action?(stop_reason), do: requires_action_event_ids(stop_reason) != []

  defp requires_action_event_ids(%{} = stop_reason) do
    if payload_value(stop_reason, "type") == "requires_action" do
      stop_reason
      |> payload_value("event_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
    else
      []
    end
  end

  defp requires_action_event_ids(_stop_reason), do: []

  defp timeline_summary(%SessionEvent{type: "user.message", content: content}),
    do: text_or_fallback(content, "User submitted a message.")

  defp timeline_summary(%SessionEvent{type: "agent.message", content: content}),
    do: text_or_fallback(content, "Assistant response recorded.")

  defp timeline_summary(%SessionEvent{type: "agent.thinking", content: content}),
    do: text_or_fallback(content, "Model reasoning snapshot recorded.")

  defp timeline_summary(%SessionEvent{type: "session.status_running"}),
    do: "Session entered the running state."

  defp timeline_summary(%SessionEvent{type: "session.status_idle"}),
    do: "Session returned to idle."

  defp timeline_summary(%SessionEvent{type: "session.error", payload: payload}) do
    payload_value(payload, "message") || "A runtime error was recorded."
  end

  defp timeline_summary(%SessionEvent{type: "user.tool_confirmation", payload: payload}) do
    case payload_value(payload, "result") do
      "allow" -> "Operator approved the pending tool request."
      "deny" -> "Operator denied the pending tool request."
      _other -> "Operator submitted a tool confirmation."
    end
  end

  defp timeline_summary(%SessionEvent{type: "user.custom_tool_result", content: content}) do
    text_or_fallback(content, "Manual custom tool result supplied.")
  end

  defp timeline_summary(%SessionEvent{type: type, payload: payload})
       when type in @tool_use_event_types do
    tool_name = payload_value(payload, "tool_name") || "tool"

    if truthy?(payload_value(payload, "awaiting_confirmation")) do
      "#{tool_name} is waiting for approval."
    else
      "#{tool_name} started."
    end
  end

  defp timeline_summary(%SessionEvent{type: type, payload: payload})
       when type in @tool_result_event_types do
    tool_name = payload_value(payload, "tool_name") || "tool"

    if truthy?(payload_value(payload, "ok")) do
      "#{tool_name} completed successfully."
    else
      "#{tool_name} completed with an error."
    end
  end

  defp timeline_summary(%SessionEvent{type: "agent.thread_message_sent", content: content}),
    do: text_or_fallback(content, "Primary thread delegated work.")

  defp timeline_summary(%SessionEvent{type: "agent.thread_message_received", content: content}),
    do: text_or_fallback(content, "Delegate thread received work.")

  defp timeline_summary(%SessionEvent{type: "session.thread_created", payload: payload}) do
    "Delegate thread created for agent #{payload_value(payload, "agent_id") || "unknown"}."
  end

  defp timeline_summary(%SessionEvent{type: "session.thread_idle", payload: payload}) do
    "Thread #{payload_value(payload, "session_thread_id") || "unknown"} returned to idle."
  end

  defp timeline_summary(%SessionEvent{content: content, payload: payload}) do
    case text_content(content) do
      "" when is_map(payload) and map_size(payload) > 0 -> pretty_data(payload)
      "" -> "Event recorded."
      text -> text
    end
  end

  defp text_or_fallback(content, fallback) do
    case text_content(content) do
      "" -> fallback
      text -> text
    end
  end

  defp text_content(content) when is_list(content) do
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

  defp text_content(_content), do: ""

  defp event_thread_label(%SessionEvent{session_thread_id: nil}, _thread_labels), do: "Session"

  defp event_thread_label(%SessionEvent{session_thread_id: thread_id}, thread_labels) do
    Map.get(thread_labels, thread_id, short_id(thread_id))
  end

  defp event_timestamp(%SessionEvent{} = event) do
    event.processed_at
    |> case do
      %DateTime{} = processed_at -> processed_at
      _other -> event.created_at
    end
    |> ConsoleHelpers.format_timestamp()
  end

  defp pretty_event(%SessionEvent{} = event) do
    event
    |> SessionEventDefinition.serialize_event()
    |> pretty_data()
  end

  defp pretty_data(nil), do: "(none)"
  defp pretty_data(value) when is_binary(value), do: value

  defp pretty_data(value) when is_map(value) or is_list(value) do
    Jason.encode!(value, pretty: true)
  end

  defp pretty_data(value), do: inspect(value, pretty: true)

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || existing_atom_value(payload, key)
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp payload_value(_payload, _key), do: nil

  defp existing_atom_value(payload, key) do
    key
    |> String.to_existing_atom()
    |> then(&Map.get(payload, &1))
  end

  defp selected_thread?(nil, _thread), do: false
  defp selected_thread?(%SessionThread{id: id}, %SessionThread{id: id}), do: true
  defp selected_thread?(_selected_thread, _thread), do: false

  defp trace_scope_path(%Session{} = session, nil), do: ~p"/console/sessions/#{session.id}"

  defp trace_scope_path(%Session{} = session, %SessionThread{} = thread) do
    ~p"/console/sessions/#{session.id}?thread_id=#{thread.id}"
  end

  defp detail_title(%Session{} = session) do
    session.title || "Session #{short_id(session.id)}"
  end

  defp session_agent_name(%Session{agent: %{name: name}}) when is_binary(name), do: name
  defp session_agent_name(%Session{} = session), do: short_id(session.agent_id)

  defp session_model(%Session{agent_version: %{model: model}}) when is_map(model) do
    payload_value(model, "id") || "Unknown model"
  end

  defp session_model(%Session{}), do: "Unknown model"

  defp thread_summary(%Session{threads: threads}) do
    count =
      threads
      |> List.wrap()
      |> length()

    if count > 1, do: "#{count} threads", else: "Primary only"
  end

  defp thread_scope_label(%SessionThread{} = thread) do
    role =
      thread.role
      |> to_string()
      |> String.capitalize()

    agent_name =
      case thread.agent do
        %{name: name} when is_binary(name) -> name
        _other -> short_id(thread.agent_id)
      end

    "#{role} · #{agent_name}"
  end

  defp short_id(nil), do: "unknown"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp status_label(status) when is_atom(status), do: status |> to_string() |> String.capitalize()
  defp status_label(status) when is_binary(status), do: String.capitalize(status)
  defp status_label(_status), do: "Unknown"

  defp confirmation_message("allow"), do: "Approval submitted. The session resumed."

  defp confirmation_message("deny"),
    do: "Denial submitted. The session resumed with a rejected tool result."

  defp confirmation_message(_result), do: "Confirmation submitted."

  defp count_sessions(sessions, status) do
    Enum.count(sessions, &(to_string(&1.status) == status))
  end

  defp count_requires_action(sessions) do
    Enum.count(sessions, &requires_action?(&1.stop_reason))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp format_metric(nil), do: "0"
  defp format_metric(value) when is_integer(value), do: Integer.to_string(value)
  defp format_metric(value), do: to_string(value)

  defp event_badge_class("session.error"),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-rose-800"

  defp event_badge_class(type) when type in @tool_use_event_types do
    "inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-amber-900"
  end

  defp event_badge_class(type) when type in @tool_result_event_types do
    "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-900"
  end

  defp event_badge_class(_type) do
    "inline-flex items-center rounded-full bg-cyan-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-cyan-900"
  end

  defp status_badge_class(:running),
    do:
      "inline-flex items-center rounded-full bg-cyan-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-cyan-900"

  defp status_badge_class(:archived),
    do:
      "inline-flex items-center rounded-full bg-neutral-900 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-white"

  defp status_badge_class(_status),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-900"

  defp detail_status_badge_class(status) do
    base =
      "inline-flex items-center rounded-full px-3 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.2em] "

    case status do
      :running -> base <> "bg-cyan-300/90 text-cyan-950"
      :archived -> base <> "bg-white/15 text-white"
      _other -> base <> "bg-emerald-300/90 text-emerald-950"
    end
  end

  defp tool_kind_label(:builtin), do: "Built-in"
  defp tool_kind_label(:mcp), do: "MCP"
  defp tool_kind_label(:custom), do: "Custom"

  defp tool_kind_badge_class(:builtin),
    do:
      "inline-flex items-center rounded-full bg-slate-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-slate-800"

  defp tool_kind_badge_class(:mcp),
    do:
      "inline-flex items-center rounded-full bg-cyan-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-cyan-900"

  defp tool_kind_badge_class(:custom),
    do:
      "inline-flex items-center rounded-full bg-violet-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-violet-900"

  defp tool_status_label(:completed), do: "Completed"
  defp tool_status_label(:errored), do: "Errored"
  defp tool_status_label(:resolved), do: "Resolved"
  defp tool_status_label(:awaiting_confirmation), do: "Awaiting approval"
  defp tool_status_label(:awaiting_result), do: "Awaiting result"
  defp tool_status_label(:started), do: "Started"

  defp tool_status_badge_class(:completed),
    do:
      "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-900"

  defp tool_status_badge_class(:errored),
    do:
      "inline-flex items-center rounded-full bg-rose-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-rose-900"

  defp tool_status_badge_class(:resolved),
    do:
      "inline-flex items-center rounded-full bg-sky-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-sky-900"

  defp tool_status_badge_class(:awaiting_confirmation),
    do:
      "inline-flex items-center rounded-full bg-amber-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-amber-900"

  defp tool_status_badge_class(:awaiting_result),
    do:
      "inline-flex items-center rounded-full bg-violet-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-violet-900"

  defp tool_status_badge_class(:started),
    do:
      "inline-flex items-center rounded-full bg-neutral-200 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-neutral-700"

  defp tool_entry_summary(%{kind: :mcp} = entry) do
    remote_tool_name = payload_value(entry.use_event.payload, "remote_tool_name")
    server_name = payload_value(entry.use_event.payload, "mcp_server_name")
    "Remote tool #{remote_tool_name || entry.tool_name} on #{server_name || "MCP"}."
  end

  defp tool_entry_summary(%{kind: :custom}),
    do: "Custom tool execution tracked in the session event log."

  defp tool_entry_summary(_entry), do: "Built-in tool execution captured from the runtime."

  defp metric_card(assigns) do
    ~H"""
    <div>
      <p class="text-xs uppercase tracking-[0.2em] text-current/65">{@label}</p>
      <p class="mt-2 text-2xl font-semibold tracking-tight">{@value}</p>
    </div>
    """
  end

  defp console_tab(%{navigate: nil} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full border border-white/15 bg-white/10 px-4 py-2 text-sm font-medium text-white">
      {@label}
    </span>
    """
  end

  defp console_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="inline-flex items-center rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-white/80 transition hover:bg-white/10 hover:text-white"
    >
      {@label}
    </.link>
    """
  end

  defp trace_scope_button(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class={[
        "inline-flex items-center rounded-full px-4 py-2 text-sm font-medium transition",
        if(@active,
          do: "border border-cyan-300 bg-cyan-50 text-cyan-900",
          else:
            "border border-neutral-200 bg-neutral-50 text-neutral-600 hover:border-cyan-300 hover:bg-cyan-50 hover:text-cyan-900"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end
end
