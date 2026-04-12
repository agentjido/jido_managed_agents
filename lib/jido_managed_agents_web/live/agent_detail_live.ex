defmodule JidoManagedAgentsWeb.AgentDetailLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.SessionDefinition
  alias JidoManagedAgents.Sessions.SessionEventDefinition
  alias JidoManagedAgents.Sessions.SessionEventLog
  alias JidoManagedAgents.Sessions.SessionRuntime
  alias JidoManagedAgents.Sessions.SessionSkillLimit
  alias JidoManagedAgents.Sessions.SessionVault
  alias JidoManagedAgents.Sessions.Workspace
  alias JidoManagedAgentsWeb.ConsoleData
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    environments = Enum.filter(ConsoleData.list_environments(actor), &is_nil(&1.archived_at))
    vaults = ConsoleData.list_vaults(actor)

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:page_title, "Agent")
     |> assign(:agent, nil)
     |> assign(:versions, [])
     |> assign(:selected_version, nil)
     |> assign(:current_tab, "agent")
     |> assign(:agent_sessions, [])
     |> assign(:environments, environments)
     |> assign(:vaults, vaults)
     |> assign(:launch_errors, [])
     |> assign(:launch_form_params, default_launch_form(environments))
     |> assign(:launch_form, to_form(default_launch_form(environments), as: :launch))
     |> assign(:pending_count, ConsoleData.pending_sessions_count(actor))}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, %Agent{} = agent} <- ConsoleData.fetch_agent(id, actor),
         {:ok, versions} <- ConsoleData.list_agent_versions(agent, actor) do
      selected_version = resolve_selected_version(versions, Map.get(params, "version"))
      current_tab = if Map.get(params, "tab") == "sessions", do: "sessions", else: "agent"

      {:noreply,
       socket
       |> assign(:agent, agent)
       |> assign(:versions, versions)
       |> assign(:selected_version, selected_version)
       |> assign(:current_tab, current_tab)
       |> assign(:agent_sessions, ConsoleData.list_agent_sessions(agent.id, actor))
       |> assign(:page_title, agent.name)}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Agent not found.")
         |> push_navigate(to: ~p"/console/agents")}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, ConsoleHelpers.error_message(error))
         |> push_navigate(to: ~p"/console/agents")}
    end
  end

  @impl true
  def handle_event("choose_version", %{"version" => %{"value" => version}}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         detail_path(socket.assigns.agent.id,
           version: version,
           tab: socket.assigns.current_tab
         )
     )}
  end

  def handle_event("validate_launch", %{"launch" => params}, socket) do
    params = normalize_launch_form(params, socket.assigns.environments)

    {:noreply,
     socket
     |> assign(:launch_form_params, params)
     |> assign(:launch_form, to_form(params, as: :launch))
     |> assign(:launch_errors, launch_validation_errors(params))}
  end

  def handle_event("launch_session", %{"launch" => params}, socket) do
    actor = socket.assigns.current_user
    params = normalize_launch_form(params, socket.assigns.environments)

    socket =
      socket
      |> assign(:launch_form_params, params)
      |> assign(:launch_form, to_form(params, as: :launch))
      |> assign(:launch_errors, launch_validation_errors(params))

    with [] <- socket.assigns.launch_errors,
         {:ok, %Session{} = session} <- create_session(socket.assigns.agent, params, actor),
         :ok <- append_prompt(session, params["prompt"], actor),
         :ok <- start_session_runtime(session.id, actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Session started.")
       |> push_navigate(to: ~p"/console/sessions/#{session.id}")}
    else
      errors when is_list(errors) ->
        {:noreply, socket}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:launch_errors, [ConsoleHelpers.error_message(error)])
         |> put_flash(:error, ConsoleHelpers.error_message(error))}
    end
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
      <div :if={@agent} class="space-y-6">
        <section class="console-panel space-y-4">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <h1 class="console-title">{@agent.name}</h1>
                <.status_badge status={if(is_nil(@agent.archived_at), do: "active", else: "archived")} />
              </div>
              <p class="console-copy max-w-3xl">{@agent.description || "No description yet."}</p>
              <p class="console-list-meta">
                Updated {ConsoleHelpers.format_timestamp(@agent.updated_at)} · {ConsoleHelpers.agent_model(
                  @selected_version
                )}
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <.form
                for={%{"value" => @selected_version.version}}
                as={:version}
                phx-change="choose_version"
              >
                <select
                  name="version[value]"
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-3 py-2 text-sm text-[var(--text-strong)]"
                >
                  <option
                    :for={version <- @versions}
                    value={version.version}
                    selected={version.version == @selected_version.version}
                  >
                    v{version.version}{if(version.version == hd(@versions).version,
                      do: " (latest)",
                      else: ""
                    )}
                  </option>
                </select>
              </.form>

              <.link
                navigate={~p"/console/agents/#{@agent.id}/edit"}
                class="console-button console-button-secondary"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit
              </.link>
            </div>
          </div>

          <.console_tabs tabs={[
            %{
              label: "Agent",
              patch: detail_path(@agent.id, version: @selected_version.version, tab: "agent"),
              active: @current_tab == "agent"
            },
            %{
              label: "Sessions",
              patch: detail_path(@agent.id, version: @selected_version.version, tab: "sessions"),
              active: @current_tab == "sessions",
              count: length(@agent_sessions)
            }
          ]} />
        </section>

        <section
          :if={@current_tab == "agent"}
          class="grid gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]"
        >
          <div class="space-y-6">
            <section class="console-panel space-y-4">
              <div class="space-y-1">
                <p class="console-label">Model</p>
                <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                  {ConsoleHelpers.agent_model(@selected_version)}
                </h2>
              </div>
              <p class="console-list-meta">
                Provider: {ConsoleHelpers.payload_value(@selected_version.model, "provider") ||
                  "unknown"}
              </p>
            </section>

            <details class="console-panel" open>
              <summary class="flex min-h-[44px] cursor-pointer items-center justify-between gap-3 text-left">
                <span>
                  <span class="console-label">System Prompt</span>
                  <span class="block text-lg font-semibold text-[var(--text-strong)]">
                    Instructions
                  </span>
                </span>
                <.icon name="hero-chevron-down" class="size-4 text-[var(--text-faint)]" />
              </summary>
              <div class="pt-4">
                <pre class="console-code-block">{@selected_version.system || "No system prompt saved for this version."}</pre>
              </div>
            </details>

            <details class="console-panel" open>
              <summary class="flex min-h-[44px] cursor-pointer items-center justify-between gap-3 text-left">
                <span>
                  <span class="console-label">Tools</span>
                  <span class="block text-lg font-semibold text-[var(--text-strong)]">
                    {length(@selected_version.tools || [])} attached
                  </span>
                </span>
                <.icon name="hero-chevron-down" class="size-4 text-[var(--text-faint)]" />
              </summary>
              <div class="space-y-3 pt-4">
                <div :if={(@selected_version.tools || []) == []}>
                  <.empty_state
                    title="No tools"
                    description="This version does not expose any built-in, MCP, or custom tools."
                  />
                </div>

                <div
                  :for={tool <- @selected_version.tools || []}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
                >
                  <div class="space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="text-sm font-semibold text-[var(--text-strong)]">
                        {Map.get(tool, :name) || Map.get(tool, "name") || Map.get(tool, :type)}
                      </p>
                      <.status_badge
                        status={Map.get(tool, :type) || Map.get(tool, "type")}
                        size="small"
                      />
                      <.status_badge
                        :if={Map.get(tool, :permission_policy) || Map.get(tool, "permission_policy")}
                        status={
                          Map.get(tool, :permission_policy) || Map.get(tool, "permission_policy")
                        }
                        size="small"
                      />
                    </div>
                    <p class="console-copy">
                      {Map.get(tool, :description) || Map.get(tool, "description") ||
                        "No description yet."}
                    </p>
                  </div>
                </div>
              </div>
            </details>
          </div>

          <div class="space-y-6">
            <details class="console-panel" open>
              <summary class="flex min-h-[44px] cursor-pointer items-center justify-between gap-3 text-left">
                <span>
                  <span class="console-label">MCP Servers</span>
                  <span class="block text-lg font-semibold text-[var(--text-strong)]">
                    {length(@selected_version.mcp_servers || [])} connected
                  </span>
                </span>
                <.icon name="hero-chevron-down" class="size-4 text-[var(--text-faint)]" />
              </summary>
              <div class="space-y-3 pt-4">
                <div :if={(@selected_version.mcp_servers || []) == []}>
                  <.empty_state
                    title="No MCP servers"
                    description="This version runs without any remote MCP endpoints."
                  />
                </div>

                <div
                  :for={server <- @selected_version.mcp_servers || []}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
                >
                  <div class="space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="text-sm font-semibold text-[var(--text-strong)]">
                        {Map.get(server, "name") || Map.get(server, :name)}
                      </p>
                      <.status_badge
                        status={Map.get(server, "type") || Map.get(server, :type) || "mcp"}
                        size="small"
                      />
                    </div>
                    <p class="console-list-meta">
                      {Map.get(server, "url") || Map.get(server, :url) || "No URL"}
                    </p>
                  </div>
                </div>
              </div>
            </details>

            <section class="console-panel space-y-4">
              <div class="space-y-1">
                <p class="console-label">Skills</p>
                <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                  {length(@selected_version.agent_version_skills || [])} linked
                </h2>
              </div>
              <div :if={(@selected_version.agent_version_skills || []) == []}>
                <.empty_state
                  title="No skills"
                  description="This version runs without pinned skill references."
                />
              </div>
              <div :if={(@selected_version.agent_version_skills || []) != []} class="space-y-3">
                <div
                  :for={link <- @selected_version.agent_version_skills || []}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-[var(--text-strong)]">
                      {link.skill.name}
                    </p>
                    <.status_badge status={link.kind || "skill"} size="small" />
                    <span
                      :if={link.skill_version}
                      class="console-badge console-badge-neutral px-2 py-1 text-[10px]"
                    >
                      v{link.skill_version.version}
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <section class="console-panel space-y-4">
              <div class="space-y-1">
                <p class="console-label">Callable Agents</p>
                <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                  {length(@selected_version.agent_version_callable_agents || [])} available
                </h2>
              </div>
              <div :if={(@selected_version.agent_version_callable_agents || []) == []}>
                <.empty_state
                  title="No callable agents"
                  description="This version does not delegate to any sibling agents."
                />
              </div>
              <div
                :if={(@selected_version.agent_version_callable_agents || []) != []}
                class="space-y-3"
              >
                <div
                  :for={link <- @selected_version.agent_version_callable_agents || []}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm font-semibold text-[var(--text-strong)]">
                      {link.callable_agent.name}
                    </p>
                    <span
                      :if={link.callable_agent_version}
                      class="console-badge console-badge-neutral px-2 py-1 text-[10px]"
                    >
                      v{link.callable_agent_version.version}
                    </span>
                  </div>
                </div>
              </div>
            </section>

            <details :if={map_size(@selected_version.metadata || %{}) > 0} class="console-panel">
              <summary class="flex min-h-[44px] cursor-pointer items-center justify-between gap-3 text-left">
                <span>
                  <span class="console-label">Metadata</span>
                  <span class="block text-lg font-semibold text-[var(--text-strong)]">
                    Structured fields
                  </span>
                </span>
                <.icon name="hero-chevron-down" class="size-4 text-[var(--text-faint)]" />
              </summary>
              <div class="pt-4">
                <.json_block data={@selected_version.metadata} />
              </div>
            </details>
          </div>
        </section>

        <section
          :if={@current_tab == "sessions"}
          class="grid gap-6 xl:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]"
        >
          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Start Session</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">
                Open a conversation with this agent
              </h2>
            </div>

            <div
              :if={@launch_errors != []}
              class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] p-4 text-sm text-[var(--danger)]"
            >
              <p :for={error <- @launch_errors}>{error}</p>
            </div>

            <.form
              for={@launch_form}
              id="agent-launch-form"
              class="space-y-4"
              phx-change="validate_launch"
              phx-submit="launch_session"
            >
              <div class="grid gap-4 md:grid-cols-2">
                <div>
                  <label class="console-label" for="launch-title">Title</label>
                  <input
                    id="launch-title"
                    name="launch[title]"
                    value={@launch_form_params["title"]}
                    placeholder="Sprint retro facilitator"
                    class="w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-3 py-3 text-sm text-[var(--text-strong)] outline-none transition focus:border-[var(--border-strong)]"
                  />
                </div>
                <div>
                  <label class="console-label" for="launch-environment">Environment</label>
                  <select
                    id="launch-environment"
                    name="launch[environment_id]"
                    class="w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-3 py-3 text-sm text-[var(--text-strong)] outline-none transition focus:border-[var(--border-strong)]"
                  >
                    <option
                      :for={environment <- @environments}
                      value={environment.id}
                      selected={environment.id == @launch_form_params["environment_id"]}
                    >
                      {environment.name}
                    </option>
                  </select>
                </div>
              </div>

              <div>
                <label class="console-label" for="launch-prompt">Opening message</label>
                <textarea
                  id="launch-prompt"
                  name="launch[prompt]"
                  rows="5"
                  placeholder="Ask the agent to do the first piece of work here."
                  class="w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] px-3 py-3 text-sm leading-7 text-[var(--text-strong)] outline-none transition focus:border-[var(--border-strong)]"
                >{@launch_form_params["prompt"]}</textarea>
                <p class="console-field-note">
                  This becomes the first `user.message` turn so the session detail page opens with a real conversation history.
                </p>
              </div>

              <div :if={@vaults != []} class="space-y-3">
                <p class="console-label">Vaults</p>
                <div class="grid gap-3">
                  <label
                    :for={vault <- @vaults}
                    class="flex min-h-[44px] items-center gap-3 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-3 py-3"
                  >
                    <input
                      type="checkbox"
                      name="launch[vault_ids][]"
                      value={vault.id}
                      checked={vault.id in List.wrap(@launch_form_params["vault_ids"])}
                      class="size-4 rounded border-[var(--border-strong)] text-[var(--brand)]"
                    />
                    <span class="min-w-0">
                      <span class="block text-sm font-medium text-[var(--text-strong)]">
                        {vault.name}
                      </span>
                      <span class="block text-xs text-[var(--text-muted)]">
                        {vault.description || "No description yet."}
                      </span>
                    </span>
                  </label>
                </div>
              </div>

              <div class="flex flex-wrap gap-3">
                <button type="submit" class="console-button console-button-primary">
                  <.icon name="hero-paper-airplane" class="size-4" /> Start Session
                </button>
                <.link
                  navigate={~p"/console/sessions"}
                  class="console-button console-button-secondary"
                >
                  View All Sessions
                </.link>
              </div>
            </.form>
          </section>

          <section class="console-panel space-y-4">
            <div class="space-y-1">
              <p class="console-label">Recent Sessions</p>
              <h2 class="text-lg font-semibold text-[var(--text-strong)]">This agent's history</h2>
            </div>

            <div :if={@agent_sessions == []}>
              <.empty_state
                title="No sessions yet"
                description="Start the first session for this agent from the form on the left."
              />
            </div>

            <div :if={@agent_sessions != []} class="space-y-3">
              <.link
                :for={session <- @agent_sessions}
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
                    {ConsoleHelpers.session_model(session)} · {length(session.threads || [])} thread(s) · {ConsoleHelpers.format_timestamp(
                      session.created_at
                    )}
                  </p>
                </div>
              </.link>
            </div>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp resolve_selected_version([version | _rest], nil), do: version

  defp resolve_selected_version(versions, value) do
    version_number =
      case Integer.parse(to_string(value)) do
        {parsed, _rest} -> parsed
        :error -> nil
      end

    Enum.find(versions, hd(versions), &(&1.version == version_number))
  end

  defp detail_path(agent_id, params) do
    version = params[:version]
    tab = params[:tab]
    ~p"/console/agents/#{agent_id}?version=#{version}&tab=#{tab}"
  end

  defp default_launch_form(environments) do
    %{
      "environment_id" => default_environment_id(environments),
      "title" => "",
      "prompt" => "",
      "vault_ids" => []
    }
  end

  defp normalize_launch_form(params, environments) when is_map(params) do
    %{
      "environment_id" => Map.get(params, "environment_id", default_environment_id(environments)),
      "title" => Map.get(params, "title", ""),
      "prompt" => Map.get(params, "prompt", ""),
      "vault_ids" => Enum.reject(List.wrap(Map.get(params, "vault_ids", [])), &(&1 in [nil, ""]))
    }
  end

  defp default_environment_id([environment | _rest]), do: environment.id
  defp default_environment_id([]), do: ""

  defp launch_validation_errors(params) do
    []
    |> maybe_add_error(params["environment_id"] in [nil, ""], "Select an environment.")
    |> maybe_add_error(String.trim(params["prompt"] || "") == "", "Opening message is required.")
  end

  defp maybe_add_error(errors, true, error), do: errors ++ [error]
  defp maybe_add_error(errors, false, _error), do: errors

  defp create_session(%Agent{} = agent, params, actor) do
    session_params =
      %{
        "agent" => agent.id,
        "environment_id" => params["environment_id"],
        "title" => ConsoleHelpers.blank_to_nil(params["title"]),
        "vault_ids" => List.wrap(params["vault_ids"])
      }
      |> ConsoleHelpers.compact_map()

    with {:ok, payload} <- SessionDefinition.normalize_create_payload(session_params, actor) do
      create_session_record(payload, actor)
    end
  end

  defp create_session_record(%{agent: %Agent{} = agent, session: attrs}, actor) do
    opts = [actor: actor, domain: Sessions]
    resources = [Workspace, Session, SessionVault]

    with :ok <- SessionSkillLimit.validate(Map.get(attrs, :agent_version_id), actor) do
      Ash.transact(resources, fn ->
        with {:ok, %Workspace{} = workspace} <- resolve_or_create_workspace(agent, actor),
             {:ok, %Session{} = session} <- create_persisted_session(attrs, workspace, opts),
             {:ok, %Session{} = loaded_session} <- load_session(session.id, actor) do
          loaded_session
        end
      end)
    end
    |> map_create_session_error()
  end

  defp resolve_or_create_workspace(%Agent{} = agent, actor) do
    query =
      Workspace
      |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Sessions)
      |> Ash.Query.filter(user_id == ^actor.id and agent_id == ^agent.id)

    case Ash.read_one(query) do
      {:ok, %Workspace{} = workspace} ->
        {:ok, workspace}

      {:ok, nil} ->
        Workspace
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: actor.id,
            agent_id: agent.id,
            name: "#{agent.name} workspace"
          },
          actor: actor,
          domain: Sessions
        )
        |> Ash.create(
          upsert?: true,
          upsert_identity: :unique_workspace_per_user_agent,
          upsert_fields: [],
          touch_update_defaults?: false
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_persisted_session(attrs, %Workspace{} = workspace, opts) do
    Session
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :workspace_id, workspace.id), opts)
    |> Ash.create()
  end

  defp load_session(session_id, actor) do
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: actor, domain: Sessions)
      |> Ash.Query.load([:agent_version, :session_vaults])

    case Ash.read_one(query) do
      {:ok, %Session{} = session} -> {:ok, session}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp append_prompt(_session, prompt, _actor) when prompt in [nil, ""], do: :ok

  defp append_prompt(%Session{} = session, prompt, actor) do
    params = %{
      "type" => "user.message",
      "content" => [%{"type" => "text", "text" => prompt}]
    }

    with {:ok, events} <- SessionEventDefinition.normalize_append_payload(params, session, actor),
         {:ok, _appended_events} <- SessionEventLog.append_user_events(session, events, actor) do
      :ok
    end
  end

  defp start_session_runtime(session_id, actor) do
    case Task.Supervisor.start_child(JidoManagedAgents.TaskSupervisor, fn ->
           try do
             SessionRuntime.run(session_id, actor)
           rescue
             _error -> :error
           end
         end) do
      {:ok, _pid} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp map_create_session_error({:error, %Ash.Error.Invalid{} = error}) do
    if Exception.message(error) =~ "workspace already has an active session" do
      {:error,
       {:conflict,
        "This agent already has an active workspace session. Open it from Sessions or finish it before starting a new one."}}
    else
      {:error, error}
    end
  end

  defp map_create_session_error(result), do: result
end
