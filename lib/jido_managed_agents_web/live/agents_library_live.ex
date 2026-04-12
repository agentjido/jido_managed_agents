defmodule JidoManagedAgentsWeb.AgentsLibraryLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  alias JidoManagedAgentsWeb.ConsoleData
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    agents = ConsoleData.list_agents(actor)
    filters = default_filters()

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:page_title, "Agents")
     |> assign(:all_agents, agents)
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:agents, filter_agents(agents, filters))
     |> assign(:pending_count, ConsoleData.pending_sessions_count(actor))}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = normalize_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:agents, filter_agents(socket.assigns.all_agents, filters))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:agents}
      pending_count={@pending_count}
    >
      <.page_header
        title="Agents"
        description="Browse the catalog, inspect current versions, and move into a read-first detail screen before editing."
      >
        <:actions>
          <.link navigate={~p"/console/agents/new"} class="console-button console-button-primary">
            <.icon name="hero-plus" class="size-4" /> Create Agent
          </.link>
        </:actions>
      </.page_header>

      <section class="console-panel space-y-4">
        <.form
          for={@filter_form}
          id="agent-filters"
          class="flex flex-col gap-3 md:flex-row md:items-center"
          phx-change="filter"
        >
          <div class="relative min-w-0 flex-1">
            <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-faint)]">
              <.icon name="hero-magnifying-glass" class="size-4" />
            </span>
            <input
              type="text"
              name="filters[search]"
              value={@filters["search"]}
              placeholder="Search agents"
              class="w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-10 py-3 text-sm text-[var(--text-strong)] outline-none transition focus:border-[var(--border-strong)]"
            />
          </div>

          <div class="flex flex-wrap gap-2">
            <button
              :for={filter <- [{"all", "All"}, {"active", "Active"}, {"archived", "Archived"}]}
              type="submit"
              name="filters[status]"
              value={elem(filter, 0)}
              class={[
                "console-button",
                if(@filters["status"] == elem(filter, 0),
                  do: "console-button-primary",
                  else: "console-button-secondary"
                )
              ]}
            >
              {elem(filter, 1)}
            </button>
          </div>
        </.form>
      </section>

      <section class="space-y-3">
        <div :if={@agents == []}>
          <.empty_state
            title="No agents matched"
            description="Try a broader search or clear the archived filter."
          />
        </div>

        <.link
          :for={agent <- @agents}
          navigate={~p"/console/agents/#{agent.id}"}
          class="console-list-link"
        >
          <div class="console-list-row">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-2">
                <p class="truncate text-sm font-semibold text-[var(--text-strong)]">{agent.name}</p>
                <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                  v{agent.latest_version.version}
                </span>
                <.status_badge :if={!is_nil(agent.archived_at)} status="archived" size="small" />
              </div>
              <p class="console-copy line-clamp-2 max-w-3xl">
                {agent.description || "No description yet."}
              </p>
              <p class="console-list-meta">
                {ConsoleHelpers.agent_model(agent.latest_version)} · Updated {ConsoleHelpers.format_timestamp(
                  agent.updated_at
                )}
              </p>
            </div>

            <.icon name="hero-chevron-right" class="mt-1 size-4 shrink-0 text-[var(--text-faint)]" />
          </div>
        </.link>
      </section>
    </Layouts.app>
    """
  end

  defp default_filters do
    %{"search" => "", "status" => "all"}
  end

  defp normalize_filters(params) do
    %{
      "search" => Map.get(params, "search", ""),
      "status" => Map.get(params, "status", "all")
    }
  end

  defp filter_agents(agents, filters) do
    search = filters["search"] |> String.downcase() |> String.trim()
    status = filters["status"]

    Enum.filter(agents, fn agent ->
      matches_status? = status_match?(agent, status)
      matches_search? = search == "" or search_match?(agent, search)
      matches_status? and matches_search?
    end)
  end

  defp status_match?(agent, "active"), do: is_nil(agent.archived_at)
  defp status_match?(agent, "archived"), do: not is_nil(agent.archived_at)
  defp status_match?(_agent, _status), do: true

  defp search_match?(agent, search) do
    haystack =
      [agent.name, agent.description, ConsoleHelpers.agent_model(agent.latest_version)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, search)
  end
end
