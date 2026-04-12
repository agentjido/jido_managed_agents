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
     |> assign(:all_sessions, [])
     |> assign(:sessions, [])
     |> assign(:session_filters, default_session_filters())
     |> assign(:session_filter_form, to_form(default_session_filters(), as: :filters))
     |> assign(:view_tab, "transcript")
     |> assign(:debug_tab, "timeline")
     |> assign(:selected_event_id, nil)
     |> assign(:composer_params, default_composer_params())
     |> assign(:composer_form, to_form(default_composer_params(), as: :composer))
     |> assign(:pending_count, 0)
     |> assign_detail(nil, nil)}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    actor = socket.assigns.current_user
    sessions = list_sessions(actor)
    filters = socket.assigns.session_filters

    {:noreply,
     socket
     |> assign(:page_title, "Sessions")
     |> assign(:all_sessions, sessions)
     |> assign(:sessions, filter_sessions(sessions, filters))
     |> assign(:pending_count, count_requires_action(sessions))
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
         |> assign(:pending_count, pending_session_count(actor))
         |> assign(:sessions, [])
         |> assign(:all_sessions, [])
         |> assign(:selected_event_id, nil)
         |> assign(:composer_params, default_composer_params())
         |> assign(:composer_form, to_form(default_composer_params(), as: :composer))
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

  def handle_event("filter_sessions", %{"filters" => params}, socket) do
    filters = normalize_session_filters(params)

    {:noreply,
     socket
     |> assign(:session_filters, filters)
     |> assign(:session_filter_form, to_form(filters, as: :filters))
     |> assign(:sessions, filter_sessions(socket.assigns.all_sessions, filters))}
  end

  def handle_event("set_view", %{"view" => view}, socket) when view in ["transcript", "debug"] do
    {:noreply, assign(socket, :view_tab, view)}
  end

  def handle_event("set_debug_tab", %{"tab" => tab}, socket)
      when tab in ["timeline", "tools", "metrics", "raw"] do
    {:noreply, assign(socket, :debug_tab, tab)}
  end

  def handle_event("select_event", %{"id" => event_id}, socket) do
    next_id = if socket.assigns.selected_event_id == event_id, do: nil, else: event_id
    {:noreply, assign(socket, :selected_event_id, next_id)}
  end

  def handle_event("validate_composer", %{"composer" => params}, socket) do
    params = normalize_composer_params(params)

    {:noreply,
     socket
     |> assign(:composer_params, params)
     |> assign(:composer_form, to_form(params, as: :composer))}
  end

  def handle_event(
        "send_message",
        %{"composer" => params},
        %{assigns: %{session: %Session{} = session}} = socket
      ) do
    actor = socket.assigns.current_user
    params = normalize_composer_params(params)

    with message when message != "" <- String.trim(params["prompt"]),
         {:ok, events} <- normalized_user_message(message, session, actor),
         {:ok, _appended_events} <- SessionEventLog.append_user_events(session, events, actor),
         {:ok, _run_result} <- safe_run_session(session.id, actor),
         {:ok, refreshed_detail} <-
           load_detail(session.id, socket.assigns.selected_thread_id, actor) do
      {:noreply,
       socket
       |> assign(:page_title, detail_title(refreshed_detail.session))
       |> assign(:composer_params, default_composer_params())
       |> assign(:composer_form, to_form(default_composer_params(), as: :composer))
       |> assign(:pending_count, pending_session_count(actor))
       |> assign_detail(refreshed_detail, socket.assigns.selected_thread_id)}
    else
      "" ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter a message before sending.")
         |> assign(:composer_params, params)
         |> assign(:composer_form, to_form(params, as: :composer))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :selected_event,
        selected_event(assigns.display_events, assigns.selected_event_id)
      )
      |> assign(:can_compose, session_composable?(assigns[:session]))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:sessions}
      pending_count={@pending_count}
    >
      <%= if @live_action == :index do %>
        <.page_header
          title="Sessions"
          description="Browse active traces, filter down to the runs that need attention, and open a transcript-first detail view when you need to interact with the agent."
        >
          <:actions>
            <.link navigate={~p"/console/agents"} class="console-button console-button-secondary">
              <.icon name="hero-cpu-chip" class="size-4" /> Agents
            </.link>
          </:actions>
        </.page_header>

        <section class="console-grid-3">
          <.kpi_card
            label="Sessions"
            value={Integer.to_string(length(@all_sessions))}
            icon="hero-bolt"
          />
          <.kpi_card
            label="Running"
            value={Integer.to_string(count_sessions(@all_sessions, "running"))}
            icon="hero-play"
            accent="text-[var(--session)]"
          />
          <.kpi_card
            label="Needs Input"
            value={Integer.to_string(count_requires_action(@all_sessions))}
            icon="hero-exclamation-circle"
            accent={
              if(count_requires_action(@all_sessions) > 0, do: "text-[var(--accent)]", else: nil)
            }
          />
        </section>

        <section class="console-panel space-y-4">
          <.form
            for={@session_filter_form}
            id="session-filters"
            class="flex flex-col gap-3 md:flex-row md:items-center"
            phx-change="filter_sessions"
          >
            <div class="relative min-w-0 flex-1">
              <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-faint)]">
                <.icon name="hero-magnifying-glass" class="size-4" />
              </span>
              <input
                type="text"
                name="filters[search]"
                value={@session_filters["search"]}
                placeholder="Search sessions"
                class="w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-10 py-3 text-sm text-[var(--text-strong)] outline-none transition focus:border-[var(--border-strong)]"
              />
            </div>

            <div class="flex flex-wrap gap-2">
              <button
                :for={filter <- session_status_filters()}
                type="submit"
                name="filters[status]"
                value={filter.value}
                class={[
                  "console-button",
                  if(@session_filters["status"] == filter.value,
                    do: "console-button-primary",
                    else: "console-button-secondary"
                  )
                ]}
              >
                {filter.label}
              </button>
            </div>
          </.form>
        </section>

        <section class="space-y-3">
          <div :if={@sessions == []}>
            <.empty_state
              title="No sessions matched"
              description="Adjust the status filter or search term to widen the result set."
            />
          </div>

          <.link
            :for={session <- @sessions}
            navigate={~p"/console/sessions/#{session.id}"}
            id={"session-card-#{session.id}"}
            class="console-list-link"
          >
            <div class="console-list-row">
              <div class="min-w-0 space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="truncate text-sm font-semibold text-[var(--text-strong)]">
                    {detail_title(session)}
                  </p>
                  <.status_badge status={session_status_badge(session)} />
                </div>
                <p class="console-copy">
                  {session_agent_name(session)} · {session_model(session)} · {thread_summary(session)}
                </p>
                <p class="console-list-meta">
                  {ConsoleHelpers.format_timestamp(session.created_at)}
                </p>
              </div>
              <.icon name="hero-chevron-right" class="mt-1 size-4 shrink-0 text-[var(--text-faint)]" />
            </div>
          </.link>
        </section>
      <% else %>
        <section class="console-panel space-y-5">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <.link
                  navigate={~p"/console/sessions"}
                  class="console-button console-button-secondary"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> Sessions
                </.link>
                <.status_badge status={session_status_badge(@session)} />
                <.status_badge :if={@pending_confirmations != []} status="needs_input" />
              </div>
              <div>
                <h1 class="console-title">{detail_title(@session)}</h1>
                <p class="console-copy">
                  {session_agent_name(@session)} · {session_model(@session)} · {ConsoleHelpers.format_timestamp(
                    @session.created_at
                  )}
                </p>
              </div>
            </div>

            <div class="console-grid-3 w-full max-w-xl">
              <.kpi_card
                label="Threads"
                value={Integer.to_string(length(@threads))}
                icon="hero-squares-2x2"
              />
              <.kpi_card
                label="Events"
                value={Integer.to_string(length(@display_events))}
                icon="hero-list-bullet"
              />
              <.kpi_card
                label="Tokens"
                value={metric_value(@metrics, "total_tokens")}
                icon="hero-chart-bar"
                accent="text-[var(--session)]"
              />
            </div>
          </div>

          <div class="console-tabs">
            <button
              type="button"
              phx-click="set_view"
              phx-value-view="transcript"
              class={["console-tab", @view_tab == "transcript" && "console-tab-active"]}
            >
              Transcript
            </button>
            <button
              type="button"
              phx-click="set_view"
              phx-value-view="debug"
              class={["console-tab", @view_tab == "debug" && "console-tab-active"]}
            >
              Debug
            </button>
          </div>
        </section>

        <div :if={@view_tab == "transcript"} class="space-y-6">
          <section class="space-y-3">
            <div class="space-y-1">
              <p class="console-label">Thread traces</p>
              <p class="console-copy">
                Scope the transcript to the primary thread or drill into delegate work without leaving the session.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <.link
                id="trace-scope-all"
                patch={trace_scope_path(@session, nil)}
                class={[
                  "console-button",
                  if(is_nil(@selected_thread),
                    do: "console-button-primary",
                    else: "console-button-secondary"
                  )
                ]}
              >
                All traces
              </.link>
              <.link
                :for={thread <- @threads}
                id={"trace-scope-thread-#{thread.id}"}
                patch={trace_scope_path(@session, thread)}
                class={[
                  "console-button",
                  if(selected_thread?(@selected_thread, thread),
                    do: "console-button-primary",
                    else: "console-button-secondary"
                  )
                ]}
              >
                {thread_scope_label(thread)}
              </.link>
            </div>
          </section>

          <section
            :if={@latest_error_event}
            class="console-panel border-[var(--danger)]/20 bg-[var(--danger-soft)]"
          >
            <div class="space-y-2">
              <p class="console-label text-[var(--danger)]">Latest error</p>
              <p class="text-sm font-semibold text-[var(--text-strong)]">
                {timeline_summary(@latest_error_event)}
              </p>
            </div>
          </section>

          <section
            :if={@pending_confirmations != []}
            class="console-panel border-[var(--accent)]/20 bg-[var(--accent-soft)]"
          >
            <div class="space-y-4">
              <div class="space-y-1">
                <p class="console-label">Approval Required</p>
                <p class="text-sm text-[var(--text-muted)]">
                  These tool calls are blocked until an operator responds.
                </p>
              </div>

              <div class="space-y-3">
                <div
                  :for={event <- @pending_confirmations}
                  id={"pending-confirmation-#{event.id}"}
                  class="rounded-[8px] border border-[var(--accent)]/20 bg-[var(--panel-bg)] p-4"
                >
                  <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                    <div class="min-w-0 space-y-2">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class={tool_status_badge_class(:awaiting_confirmation)}>
                          {tool_status_label(:awaiting_confirmation)}
                        </span>
                        <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                          {event_thread_label(event, @thread_labels)}
                        </span>
                      </div>
                      <p class="text-sm font-semibold text-[var(--text-strong)]">
                        {timeline_summary(event)}
                      </p>
                      <pre :if={tool_request_detail(event)} class="console-code-block">
                        {tool_request_detail(event)}
                      </pre>
                    </div>

                    <div class="flex flex-wrap gap-2">
                      <button
                        id={"confirm-allow-#{event.id}"}
                        type="button"
                        phx-click="confirm_tool"
                        phx-value-tool_use_id={event.id}
                        phx-value-result="allow"
                        class="console-button console-button-primary"
                      >
                        Allow
                      </button>
                      <button
                        id={"confirm-deny-#{event.id}"}
                        type="button"
                        phx-click="confirm_tool"
                        phx-value-tool_use_id={event.id}
                        phx-value-result="deny"
                        class="console-button console-button-secondary"
                      >
                        Deny
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_320px]">
            <section
              id="session-trace"
              class="console-panel console-scroll max-h-[calc(100vh-18rem)] overflow-y-auto"
            >
              <div class="console-transcript">
                <div :if={@display_events == []}>
                  <.empty_state
                    title="No transcript events"
                    description="This trace scope does not have any visible events yet."
                  />
                </div>

                <div
                  :for={event <- @display_events}
                  class={[
                    "console-transcript-item",
                    @selected_event_id == event.id && "console-transcript-item-selected"
                  ]}
                >
                  <div class={transcript_event_class(event)}>
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0 flex-1 space-y-2">
                        <%= cond do %>
                          <% event.type == "user.message" -> %>
                            <div class="flex items-center gap-2">
                              <.status_badge status="active" size="small" />
                              <p class="text-sm font-semibold text-[var(--text-strong)]">You</p>
                              <p class="console-list-meta">{event_timestamp(event)}</p>
                            </div>
                            <p class="console-value">{text_content(event.content)}</p>
                          <% event.type == "agent.message" -> %>
                            <div class="flex flex-wrap items-center gap-2">
                              <.status_badge status="running" size="small" />
                              <p class="text-sm font-semibold text-[var(--text-strong)]">
                                {session_agent_name(@session)}
                              </p>
                              <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                                {event_thread_label(event, @thread_labels)}
                              </span>
                              <p class="console-list-meta">{event_timestamp(event)}</p>
                            </div>
                            <p class="console-value">{text_content(event.content)}</p>
                          <% event.type == "agent.thinking" -> %>
                            <div class="flex items-center gap-2">
                              <.status_badge status="running" size="small" />
                              <p class="text-sm font-semibold text-[var(--text-strong)]">Thinking</p>
                              <p class="console-list-meta">{event_timestamp(event)}</p>
                            </div>
                            <p class="console-copy italic">{timeline_summary(event)}</p>
                          <% tool_use_event?(event) or tool_result_event?(event) -> %>
                            <div class="flex flex-wrap items-center gap-2">
                              <p class="text-sm font-semibold text-[var(--text-strong)]">
                                {payload_value(event.payload, "tool_name") || "Tool"}
                              </p>
                              <span class={tool_kind_badge_class(tool_kind(event.type))}>
                                {tool_kind_label(tool_kind(event.type))}
                              </span>
                              <span
                                :if={awaiting_confirmation_event?(event)}
                                class={tool_status_badge_class(:awaiting_confirmation)}
                              >
                                {tool_status_label(:awaiting_confirmation)}
                              </span>
                              <p class="console-list-meta">{event_timestamp(event)}</p>
                            </div>
                            <p class="console-copy">{timeline_summary(event)}</p>
                            <div
                              :if={awaiting_confirmation_event?(event)}
                              class="flex flex-wrap gap-2 pt-2"
                            >
                              <button
                                type="button"
                                phx-click="confirm_tool"
                                phx-value-tool_use_id={event.id}
                                phx-value-result="allow"
                                class="console-button console-button-primary"
                              >
                                Allow
                              </button>
                              <button
                                type="button"
                                phx-click="confirm_tool"
                                phx-value-tool_use_id={event.id}
                                phx-value-result="deny"
                                class="console-button console-button-secondary"
                              >
                                Deny
                              </button>
                            </div>
                          <% true -> %>
                            <div class="flex flex-wrap items-center gap-2">
                              <span class={event_badge_class(event.type)}>{event.type}</span>
                              <p class="console-list-meta">{event_timestamp(event)}</p>
                            </div>
                            <p class="console-copy">{timeline_summary(event)}</p>
                        <% end %>
                      </div>

                      <button
                        type="button"
                        phx-click="select_event"
                        phx-value-id={event.id}
                        class="console-button console-button-ghost console-xl-up-inline-flex"
                      >
                        Inspect
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <aside class="hidden xl:block">
              <section class="console-panel sticky top-24 space-y-4">
                <div class="space-y-1">
                  <p class="console-label">Detail</p>
                  <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                    {if @selected_event,
                      do: "Event ##{@selected_event.sequence}",
                      else: "Session context"}
                  </h2>
                </div>

                <%= if @selected_event do %>
                  <div class="space-y-4">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={event_badge_class(@selected_event.type)}>
                        {@selected_event.type}
                      </span>
                      <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                        {event_thread_label(@selected_event, @thread_labels)}
                      </span>
                    </div>
                    <p class="console-copy">{timeline_summary(@selected_event)}</p>
                    <div>
                      <p class="console-label">Payload</p>
                      <.json_block
                        data={SessionEventDefinition.serialize_event(@selected_event)}
                        class="max-h-[24rem] overflow-y-auto"
                      />
                    </div>
                  </div>
                <% else %>
                  <div class="space-y-3">
                    <p class="console-copy">
                      Pick any transcript item to inspect its raw payload, thread label, and tool details without leaving the conversation flow.
                    </p>
                    <p class="console-list-meta">
                      Current scope: {@selected_trace_label}
                    </p>
                  </div>
                <% end %>
              </section>
            </aside>
          </div>

          <section :if={@can_compose} class="console-composer">
            <.form
              for={@composer_form}
              id="session-composer"
              phx-change="validate_composer"
              phx-submit="send_message"
            >
              <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
                <div class="min-w-0 flex-1">
                  <textarea
                    name="composer[prompt]"
                    rows="2"
                    placeholder="Send a follow-up to this session"
                  >{@composer_params["prompt"]}</textarea>
                </div>
                <button type="submit" class="console-button console-button-primary">
                  <.icon name="hero-paper-airplane" class="size-4" /> Send
                </button>
              </div>
            </.form>
          </section>
        </div>

        <div :if={@view_tab == "debug"} class="space-y-6">
          <section class="space-y-3">
            <div class="space-y-1">
              <p class="console-label">Thread traces</p>
              <p class="console-copy">
                Match the debug timeline to the same thread scope used in the transcript.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <.link
                id="debug-trace-scope-all"
                patch={trace_scope_path(@session, nil)}
                class={[
                  "console-button",
                  if(is_nil(@selected_thread),
                    do: "console-button-primary",
                    else: "console-button-secondary"
                  )
                ]}
              >
                All traces
              </.link>
              <.link
                :for={thread <- @threads}
                id={"debug-trace-scope-thread-#{thread.id}"}
                patch={trace_scope_path(@session, thread)}
                class={[
                  "console-button",
                  if(selected_thread?(@selected_thread, thread),
                    do: "console-button-primary",
                    else: "console-button-secondary"
                  )
                ]}
              >
                {thread_scope_label(thread)}
              </.link>
            </div>
          </section>

          <div class="console-tabs">
            <button
              :for={tab <- debug_tabs()}
              type="button"
              phx-click="set_debug_tab"
              phx-value-tab={tab.value}
              class={["console-tab", @debug_tab == tab.value && "console-tab-active"]}
            >
              {tab.label}
            </button>
          </div>

          <section
            :if={@debug_tab == "timeline"}
            id="session-timeline"
            class="console-panel space-y-3"
          >
            <div
              :if={@latest_error_event}
              class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] p-4"
            >
              <p class="text-sm font-semibold text-[var(--danger)]">Latest error</p>
              <p class="console-copy mt-2">{timeline_summary(@latest_error_event)}</p>
            </div>

            <div
              :for={event <- @display_events}
              class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                      #{event.sequence}
                    </span>
                    <span class={event_badge_class(event.type)}>{event.type}</span>
                    <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                      {event_thread_label(event, @thread_labels)}
                    </span>
                  </div>
                  <p class="console-copy">{timeline_summary(event)}</p>
                </div>
                <p class="console-list-meta">{event_timestamp(event)}</p>
              </div>
            </div>
          </section>

          <section
            :if={@debug_tab == "tools"}
            id="session-tool-executions"
            class="console-panel space-y-4"
          >
            <div :if={@tool_entries == []}>
              <.empty_state
                title="No tool executions"
                description="This trace scope has not recorded any tool use or tool result events."
              />
            </div>

            <div :if={@tool_entries != []} class="space-y-4">
              <div
                :for={entry <- @tool_entries}
                class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
              >
                <div class="space-y-3">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-[var(--text-strong)]">{entry.tool_name}</p>
                    <span class={tool_kind_badge_class(entry.kind)}>
                      {tool_kind_label(entry.kind)}
                    </span>
                    <span class={tool_status_badge_class(entry.status)}>
                      {tool_status_label(entry.status)}
                    </span>
                  </div>
                  <p class="console-copy">{tool_entry_summary(entry)}</p>
                  <div :if={entry.awaiting_confirmation?} class="flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="confirm_tool"
                      phx-value-tool_use_id={entry.use_event.id}
                      phx-value-result="allow"
                      class="console-button console-button-primary"
                    >
                      Allow
                    </button>
                    <button
                      type="button"
                      phx-click="confirm_tool"
                      phx-value-tool_use_id={entry.use_event.id}
                      phx-value-result="deny"
                      class="console-button console-button-secondary"
                    >
                      Deny
                    </button>
                  </div>
                  <div class="grid gap-4 lg:grid-cols-2">
                    <div>
                      <p class="console-label">Input</p>
                      <pre class="console-code-block">{entry.input_json}</pre>
                    </div>
                    <div>
                      <p class="console-label">Outcome</p>
                      <pre class="console-code-block">{entry.outcome_json}</pre>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section :if={@debug_tab == "metrics"} id="session-metrics" class="console-panel space-y-4">
            <%= if @metrics do %>
              <div class="console-grid-3">
                <.kpi_card
                  :for={{label, value} <- metric_entries(@metrics)}
                  label={label}
                  value={value}
                />
              </div>
            <% else %>
              <.empty_state
                title="No provider metrics"
                description="Usage data has not been recorded for this trace yet."
              />
            <% end %>
          </section>

          <section :if={@debug_tab == "raw"} id="session-raw-events" class="console-panel space-y-3">
            <div
              :for={event <- @display_events}
              class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <p class="text-sm font-semibold text-[var(--text-strong)]">
                  #{event.sequence} · {event.type}
                </p>
                <p class="console-list-meta">{event_timestamp(event)}</p>
              </div>
              <pre class="console-code-block mt-4">{pretty_event(event)}</pre>
            </div>
          </section>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp default_session_filters do
    %{"search" => "", "status" => "all"}
  end

  defp normalize_session_filters(params) do
    %{
      "search" => Map.get(params, "search", ""),
      "status" => Map.get(params, "status", "all")
    }
  end

  defp filter_sessions(sessions, filters) do
    search = filters["search"] |> String.downcase() |> String.trim()
    status = filters["status"]

    Enum.filter(sessions, fn session ->
      session_status_match?(session, status) and session_search_match?(session, search)
    end)
  end

  defp session_status_filters do
    [
      %{label: "All", value: "all"},
      %{label: "Needs Input", value: "needs_input"},
      %{label: "Running", value: "running"},
      %{label: "Finished", value: "finished"},
      %{label: "Errored", value: "errored"}
    ]
  end

  defp session_status_match?(session, "needs_input"),
    do: requires_action?(session.stop_reason)

  defp session_status_match?(session, "running"), do: to_string(session.status) == "running"

  defp session_status_match?(session, "finished"),
    do: to_string(session.status) in ["idle", "archived"]

  defp session_status_match?(session, "errored"), do: to_string(session.status) == "errored"
  defp session_status_match?(_session, _status), do: true

  defp session_search_match?(_session, ""), do: true

  defp session_search_match?(session, search) do
    haystack =
      [session.title, session_agent_name(session), session_model(session)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, search)
  end

  defp default_composer_params, do: %{"prompt" => ""}

  defp normalize_composer_params(params) do
    %{"prompt" => Map.get(params, "prompt", "")}
  end

  defp normalized_user_message(message, %Session{} = session, actor) do
    params = %{
      "type" => "user.message",
      "content" => [%{"type" => "text", "text" => message}]
    }

    SessionEventDefinition.normalize_append_payload(params, session, actor)
  end

  defp selected_event(events, nil), do: List.last(events)

  defp selected_event(events, selected_event_id) do
    Enum.find(events, List.last(events), &(&1.id == selected_event_id))
  end

  defp session_status_badge(%Session{} = session) do
    if requires_action?(session.stop_reason), do: "needs_input", else: session.status
  end

  defp session_composable?(nil), do: false

  defp session_composable?(%Session{} = session) do
    to_string(session.status) in ["idle", "running"] or requires_action?(session.stop_reason)
  end

  defp metric_value(nil, _key), do: "0"
  defp metric_value(metrics, key), do: format_metric(metrics[key] || metrics[to_string(key)])

  defp transcript_event_class(%SessionEvent{type: "agent.message"}) do
    "rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
  end

  defp transcript_event_class(%SessionEvent{type: "user.message"}) do
    "rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4"
  end

  defp transcript_event_class(%SessionEvent{type: type}) when type in @tool_use_event_types do
    "rounded-[8px] border border-[var(--accent)]/20 bg-[var(--accent-soft)] p-4"
  end

  defp transcript_event_class(%SessionEvent{type: type}) when type in @tool_result_event_types do
    "rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
  end

  defp transcript_event_class(%SessionEvent{}) do
    "rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4"
  end

  defp tool_use_event?(%SessionEvent{type: type}), do: type in @tool_use_event_types
  defp tool_use_event?(_event), do: false

  defp tool_result_event?(%SessionEvent{type: type}), do: type in @tool_result_event_types
  defp tool_result_event?(_event), do: false

  defp debug_tabs do
    [
      %{label: "Timeline", value: "timeline"},
      %{label: "Tools", value: "tools"},
      %{label: "Metrics", value: "metrics"},
      %{label: "Raw Events", value: "raw"}
    ]
  end

  defp pending_session_count(actor) do
    actor
    |> list_sessions()
    |> count_requires_action()
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

  defp tool_request_detail(%SessionEvent{} = event) do
    input = payload_value(event.payload, "input")

    cond do
      is_binary(payload_value(input, "command")) -> payload_value(input, "command")
      is_binary(payload_value(input, "prompt")) -> payload_value(input, "prompt")
      is_map(input) and map_size(input) > 0 -> pretty_data(input)
      true -> nil
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
end
