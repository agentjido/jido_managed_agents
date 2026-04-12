defmodule JidoManagedAgentsWeb.OverviewLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  alias JidoManagedAgentsWeb.ConsoleData
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    agents = ConsoleData.list_agents(actor)
    environments = ConsoleData.list_environments(actor)
    sessions = ConsoleData.list_sessions(actor, limit: 10)
    pending_sessions = Enum.filter(sessions, &ConsoleHelpers.requires_action?(&1.stop_reason))

    running_sessions_count =
      Enum.count(sessions, fn session ->
        to_string(session.status) in ["running", "idle"] or
          ConsoleHelpers.requires_action?(session.stop_reason)
      end)

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:page_title, "Overview")
     |> assign(:agents, agents)
     |> assign(:environments, environments)
     |> assign(:sessions, sessions)
     |> assign(:pending_sessions, pending_sessions)
     |> assign(:running_sessions_count, running_sessions_count)
     |> assign(:activities, activity_items(agents, environments, sessions))
     |> assign(:pending_count, length(pending_sessions))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:overview}
      pending_count={@pending_count}
    >
      <.page_header
        title="Overview"
        description="A compact operator view across agents, sessions, environments, and the work that still needs input."
      >
        <:actions>
          <.link navigate={~p"/console/agents/new"} class="console-button console-button-primary">
            <.icon name="hero-plus" class="size-4" /> New Agent
          </.link>
        </:actions>
      </.page_header>

      <section class="console-grid-4">
        <.kpi_card
          label="Agents"
          value={Integer.to_string(Enum.count(@agents, &is_nil(&1.archived_at)))}
          icon="hero-cpu-chip"
        />
        <.kpi_card
          label="Active Sessions"
          value={Integer.to_string(@running_sessions_count)}
          icon="hero-bolt"
          accent="text-[var(--session)]"
        />
        <.kpi_card
          label="Needs Input"
          value={Integer.to_string(length(@pending_sessions))}
          icon="hero-exclamation-circle"
          accent={if(@pending_sessions != [], do: "text-[var(--accent)]", else: nil)}
        />
        <.kpi_card
          label="Environments"
          value={Integer.to_string(Enum.count(@environments, &is_nil(&1.archived_at)))}
          icon="hero-server-stack"
        />
      </section>

      <section class="console-grid-2">
        <div class="space-y-6">
          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Pending Approvals</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">Sessions waiting on you</h2>
            </div>

            <div :if={@pending_sessions == []}>
              <.empty_state
                title="Nothing blocked"
                description="All recent sessions can keep moving without operator input."
              />
            </div>

            <div :if={@pending_sessions != []} class="space-y-3">
              <.link
                :for={session <- @pending_sessions}
                navigate={~p"/console/sessions/#{session.id}"}
                class="console-list-link"
              >
                <div class="console-list-row">
                  <div class="min-w-0 space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="truncate text-sm font-semibold text-[var(--text-strong)]">
                        {session.title || ConsoleHelpers.short_id(session.id)}
                      </p>
                      <.status_badge status="needs_input" />
                    </div>
                    <p class="console-list-meta">
                      {session.agent.name} · {ConsoleHelpers.session_model(session)}
                    </p>
                  </div>
                  <.icon
                    name="hero-arrow-right"
                    class="mt-1 size-4 shrink-0 text-[var(--text-faint)]"
                  />
                </div>
              </.link>
            </div>
          </section>

          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Quick Actions</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                Move straight to the common paths
              </h2>
            </div>

            <div class="grid gap-3 sm:grid-cols-2">
              <.link
                navigate={~p"/console/agents/new"}
                class="console-button console-button-secondary"
              >
                <.icon name="hero-plus" class="size-4" /> Create Agent
              </.link>
              <.link navigate={~p"/console/sessions"} class="console-button console-button-secondary">
                <.icon name="hero-bolt" class="size-4" /> Review Sessions
              </.link>
              <.link
                :if={@pending_sessions != []}
                navigate={~p"/console/sessions/#{hd(@pending_sessions).id}"}
                class="console-button console-button-secondary sm:col-span-2"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                Open Latest Pending Session
              </.link>
            </div>
          </section>
        </div>

        <section class="space-y-6">
          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Recent Sessions</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">Latest traces</h2>
            </div>

            <div :if={@sessions == []}>
              <.empty_state
                title="No sessions yet"
                description="Launch a session from an agent detail page or the builder to see it here."
              />
            </div>

            <div :if={@sessions != []} class="space-y-3">
              <.link
                :for={session <- @sessions}
                navigate={~p"/console/sessions/#{session.id}"}
                class="console-list-link"
              >
                <div class="space-y-2">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="truncate text-sm font-semibold text-[var(--text-strong)]">
                      {session.title || ConsoleHelpers.short_id(session.id)}
                    </p>
                    <.status_badge status={
                      if(ConsoleHelpers.requires_action?(session.stop_reason),
                        do: "needs_input",
                        else: session.status
                      )
                    } />
                  </div>
                  <p class="console-list-meta">
                    {session.agent.name} · {length(session.threads || [])} thread(s) · {ConsoleHelpers.format_timestamp(
                      session.created_at
                    )}
                  </p>
                </div>
              </.link>
            </div>
          </section>

          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Activity</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">Recent changes</h2>
            </div>

            <div class="space-y-3">
              <div
                :for={activity <- @activities}
                class="flex items-start gap-3 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-3"
              >
                <span class={activity_dot_class(activity.kind)}></span>
                <div class="min-w-0">
                  <.link
                    :if={activity[:path]}
                    navigate={activity.path}
                    class="text-sm font-medium text-[var(--text-strong)] hover:underline"
                  >
                    {activity.message}
                  </.link>
                  <p :if={!activity[:path]} class="text-sm font-medium text-[var(--text-strong)]">
                    {activity.message}
                  </p>
                  <p class="console-list-meta">
                    {ConsoleHelpers.format_timestamp(activity.timestamp)}
                  </p>
                </div>
              </div>
            </div>
          </section>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp activity_items(agents, environments, sessions) do
    session_items =
      Enum.map(Enum.take(sessions, 4), fn session ->
        %{
          kind: :session,
          message: "#{session.title || "Session #{ConsoleHelpers.short_id(session.id)}"} updated",
          timestamp: session.updated_at,
          path: ~p"/console/sessions/#{session.id}"
        }
      end)

    agent_items =
      Enum.map(Enum.take(agents, 3), fn agent ->
        %{
          kind: :agent,
          message: "#{agent.name} saved",
          timestamp: agent.updated_at,
          path: ~p"/console/agents/#{agent.id}"
        }
      end)

    environment_items =
      Enum.map(Enum.take(environments, 2), fn environment ->
        %{
          kind: :environment,
          message: "#{environment.name} available",
          timestamp: environment.updated_at,
          path: ~p"/console/environments/#{environment.id}/edit"
        }
      end)

    (session_items ++ agent_items ++ environment_items)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(6)
  end

  defp activity_dot_class(:agent), do: "mt-2 size-2 rounded-full bg-[var(--accent)]"
  defp activity_dot_class(:environment), do: "mt-2 size-2 rounded-full bg-[var(--success)]"
  defp activity_dot_class(_kind), do: "mt-2 size-2 rounded-full bg-[var(--session)]"
end
