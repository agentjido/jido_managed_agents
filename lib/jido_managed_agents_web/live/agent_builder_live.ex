defmodule JidoManagedAgentsWeb.AgentBuilderLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Agents.AgentDefinition
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.ModelCatalog
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.SessionDefinition
  alias JidoManagedAgents.Sessions.SessionEvent
  alias JidoManagedAgents.Sessions.SessionEventDefinition
  alias JidoManagedAgents.Sessions.SessionEventLog
  alias JidoManagedAgents.Sessions.SessionRuntime
  alias JidoManagedAgents.Sessions.SessionSkillLimit
  alias JidoManagedAgents.Sessions.SessionStream
  alias JidoManagedAgents.Sessions.SessionVault
  alias JidoManagedAgents.Sessions.Workspace
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @preview_event_limit 200

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    environments = list_environments(actor)
    skills = list_skills(actor)
    callable_agents = list_callable_agents(actor)
    vaults = list_vaults(actor)

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:environments, environments)
      |> assign(:skills, skills)
      |> assign(:callable_agents, callable_agents)
      |> assign(:vaults, vaults)
      |> assign(:agent, nil)
      |> assign(:versions, [])
      |> assign(:builder_errors, [])
      |> assign(:runner_error, nil)
      |> assign(:runner_notice, nil)
      |> assign(:runner_events, [])
      |> assign(:runner_status, nil)
      |> assign(:runner_task, nil)
      |> assign(:current_session, nil)
      |> assign(:page_title, "New Agent")
      |> assign(:builder_sections, MapSet.new(["basics", "capabilities"]))
      |> assign(:preview_tab, "json")
      |> assign(:preview_expanded, false)
      |> assign(:show_archive_confirm, false)
      |> assign(:show_version_history, false)
      |> assign(:builder_submit_attempted, false)
      |> assign_builder(default_draft(), validate?: false)
      |> assign_runner(default_runner_params(environments))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    actor = socket.assigns.current_user

    with {:ok, %Agent{} = agent} <- AgentCatalog.fetch_agent(id, actor),
         {:ok, definition} <- AgentDefinition.serialize_definition(agent, actor: actor),
         {:ok, versions} <- AgentCatalog.list_versions(agent, actor) do
      socket =
        socket
        |> maybe_unsubscribe_current_session()
        |> assign(:agent, agent)
        |> assign(:versions, versions)
        |> assign(:current_session, nil)
        |> assign(:runner_events, [])
        |> assign(:runner_status, nil)
        |> assign(:runner_error, nil)
        |> assign(:runner_notice, nil)
        |> assign(:page_title, agent.name)
        |> assign(:builder_submit_attempted, false)
        |> assign_builder(draft_from_definition(definition), validate?: false)
        |> assign_runner(default_runner_params(socket.assigns.environments))

      {:noreply, socket}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Agent not found.")
         |> push_navigate(to: ~p"/console/agents/new")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    socket =
      socket
      |> maybe_unsubscribe_current_session()
      |> assign(:agent, nil)
      |> assign(:versions, [])
      |> assign(:current_session, nil)
      |> assign(:runner_events, [])
      |> assign(:runner_status, nil)
      |> assign(:runner_error, nil)
      |> assign(:runner_notice, nil)
      |> assign(:page_title, "New Agent")
      |> assign(:builder_submit_attempted, false)
      |> assign_builder(default_draft(), validate?: false)
      |> assign_runner(default_runner_params(socket.assigns.environments))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_builder", %{"agent" => params}, socket) do
    {:noreply, assign_builder(socket, params, validate?: socket.assigns.builder_submit_attempted)}
  end

  def handle_event("toggle_builder_section", %{"section" => section}, socket) do
    sections = socket.assigns.builder_sections

    next_sections =
      if MapSet.member?(sections, section) do
        MapSet.delete(sections, section)
      else
        MapSet.put(sections, section)
      end

    {:noreply, assign(socket, :builder_sections, next_sections)}
  end

  def handle_event("set_preview_tab", %{"tab" => tab}, socket) when tab in ["json", "yaml"] do
    {:noreply, assign(socket, :preview_tab, tab)}
  end

  def handle_event("toggle_preview_expanded", _params, socket) do
    {:noreply, update(socket, :preview_expanded, &(!&1))}
  end

  def handle_event("toggle_archive_confirm", _params, socket) do
    {:noreply, update(socket, :show_archive_confirm, &(!&1))}
  end

  def handle_event("toggle_version_history", _params, socket) do
    {:noreply, update(socket, :show_version_history, &(!&1))}
  end

  def handle_event("add-item", %{"section" => section}, socket) do
    draft =
      Map.update(
        socket.assigns.draft_params,
        section,
        [default_section_item(section)],
        fn items -> List.wrap(items) ++ [default_section_item(section)] end
      )

    {:noreply, assign_builder(socket, draft, validate?: socket.assigns.builder_submit_attempted)}
  end

  def handle_event("remove-item", %{"section" => section, "index" => index}, socket) do
    draft =
      Map.update(socket.assigns.draft_params, section, [], fn items ->
        items
        |> List.wrap()
        |> List.delete_at(String.to_integer(index))
      end)

    {:noreply, assign_builder(socket, draft, validate?: socket.assigns.builder_submit_attempted)}
  end

  def handle_event("save_agent", %{"agent" => params}, socket) do
    actor = socket.assigns.current_user

    socket =
      socket
      |> assign(:builder_submit_attempted, true)
      |> assign_builder(params, validate?: true)

    if socket.assigns.builder_errors != [] do
      {:noreply, put_flash(socket, :error, hd(socket.assigns.builder_errors))}
    else
      body = socket.assigns.preview_body

      result =
        case socket.assigns.agent do
          %Agent{} = agent ->
            AgentCatalog.update_from_params(
              agent,
              Map.put(body, "version", agent.latest_version.version),
              actor
            )

          nil ->
            AgentCatalog.create_from_params(body, actor)
        end

      case result do
        {:ok, %Agent{} = agent} ->
          {:noreply, handle_saved_agent(socket, agent)}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:builder_errors, List.wrap(error_message(error)))
           |> put_flash(:error, error_message(error))}
      end
    end
  end

  def handle_event("archive_agent", _params, %{assigns: %{agent: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("archive_agent", _params, socket) do
    actor = socket.assigns.current_user

    case AgentCatalog.archive(socket.assigns.agent, actor) do
      {:ok, %Agent{} = agent} ->
        {:noreply,
         socket
         |> assign(:agent, agent)
         |> assign(:show_archive_confirm, false)
         |> put_flash(:info, "Agent archived.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("validate_runner", %{"runner" => params}, socket) do
    {:noreply, assign_runner(socket, params)}
  end

  def handle_event("launch_session", %{"runner" => params}, socket) do
    actor = socket.assigns.current_user
    socket = assign_runner(socket, params)

    with {:ok, %Agent{} = agent, socket} <- ensure_saved_agent(socket, actor),
         {:ok, %Session{} = session, socket} <- ensure_runner_session(socket, agent, actor),
         :ok <- maybe_append_prompt(session, socket.assigns.runner_params["prompt"], actor),
         {:ok, socket} <- maybe_run_session(session, socket, actor) do
      {:noreply,
       socket
       |> assign(:runner_error, nil)
       |> assign(:runner_notice, active_session_notice(session))
       |> assign(:runner_status, socket.assigns.runner_status || to_string(session.status))
       |> assign_runner(Map.put(socket.assigns.runner_params, "prompt", ""))}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :runner_error, message)}

      {:error, error} ->
        {:noreply, assign(socket, :runner_error, error_message(error))}
    end
  end

  @impl true
  def handle_info({:session_event, %SessionEvent{} = event}, socket) do
    {:noreply,
     socket
     |> assign(:runner_events, merge_runner_events(socket.assigns.runner_events, event))
     |> assign(:runner_status, status_from_event(event, socket.assigns.runner_status))
     |> assign(
       :runner_notice,
       stop_reason_notice(event.stop_reason, socket.assigns.runner_notice)
     )}
  end

  def handle_info({:session_closed, %{status: status}}, socket) do
    {:noreply, assign(socket, :runner_status, to_string(status))}
  end

  def handle_info(
        {ref, {:session_runtime_result, session_id, {:ok, result}}},
        %{assigns: %{runner_task: %Task{ref: ref}}} = socket
      ) do
    Process.demonitor(ref, [:flush])
    socket = assign(socket, :runner_task, nil)

    if current_session_id(socket) == session_id do
      {:noreply, assign(socket, :runner_status, to_string(result.session.status))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {ref, {:session_runtime_result, session_id, {:error, error}}},
        %{assigns: %{runner_task: %Task{ref: ref}}} = socket
      ) do
    Process.demonitor(ref, [:flush])
    socket = assign(socket, :runner_task, nil)

    if current_session_id(socket) == session_id do
      {:noreply, assign(socket, :runner_error, error_message(error))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{runner_task: %Task{ref: ref}}} = socket
      ) do
    socket = assign(socket, :runner_task, nil)

    if reason in [:normal, :shutdown] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :runner_error, Exception.format_exit(reason))}
    end
  end

  def handle_info({ref, {:session_runtime_result, _session_id, _result}}, socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    shutdown_runner_task(socket)

    if session_id = current_session_id(socket) do
      SessionStream.unsubscribe(session_id)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:agents}
      main_class="px-4 py-6 sm:px-6 lg:px-8"
      container_class="mx-auto max-w-7xl space-y-6"
    >
      <.page_header
        title={if(@agent, do: "Edit: #{@page_title}", else: "New Agent")}
        description={
          if @agent,
            do: "Version #{@agent.latest_version.version} · #{ConsoleHelpers.agent_model(@agent)}",
            else: "Configure a new agent"
        }
      >
        <:actions>
          <button
            :if={@agent}
            type="button"
            id="agent-archive-button"
            phx-click="toggle_archive_confirm"
            class="console-button console-button-secondary"
          >
            Archive
          </button>
          <button
            id="agent-save-button"
            type="submit"
            form="agent-builder-form"
            class="console-button console-button-primary"
          >
            {if @agent, do: "Save New Version", else: "Create Agent"}
          </button>
        </:actions>
      </.page_header>

      <div
        :if={@show_archive_confirm}
        class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] p-4"
      >
        <p class="text-sm font-medium text-[var(--text-strong)]">Archive this agent?</p>
        <p class="mt-1 text-xs text-[var(--text-muted)]">
          Archived agents cannot be used in new sessions.
        </p>
        <div class="mt-3 flex gap-2">
          <button
            type="button"
            phx-click="archive_agent"
            class="console-button console-button-primary"
          >
            Confirm Archive
          </button>
          <button
            type="button"
            phx-click="toggle_archive_confirm"
            class="console-button console-button-secondary"
          >
            Cancel
          </button>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-5">
        <div class="space-y-3 lg:col-span-3">
          <.form
            for={@builder_form}
            id="agent-builder-form"
            phx-change="validate_builder"
            phx-submit="save_agent"
            class="space-y-3"
          >
            <div
              :if={@builder_errors != []}
              id="builder-errors"
              class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] p-4 text-sm text-[var(--text-strong)]"
            >
              <p class="font-medium">The current draft has validation issues.</p>
              <ul class="mt-2 space-y-1">
                <li :for={error <- @builder_errors}>{error}</li>
              </ul>
            </div>

            <section class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]">
              <button
                type="button"
                phx-click="toggle_builder_section"
                phx-value-section="basics"
                class="flex w-full items-center justify-between p-4 text-left"
              >
                <div>
                  <h2 class="text-sm font-semibold text-[var(--text-strong)]">Basics</h2>
                  <p class="mt-0.5 text-[11px] text-[var(--text-muted)]">
                    Name, model, and system prompt
                  </p>
                </div>
                <.icon
                  name={
                    if(section_open?(@builder_sections, "basics"),
                      do: "hero-chevron-down",
                      else: "hero-chevron-right"
                    )
                  }
                  class="size-4 shrink-0 text-[var(--text-muted)]"
                />
              </button>

              <div
                :if={section_open?(@builder_sections, "basics")}
                class="border-t border-[var(--border-subtle)] px-4 pb-4 pt-3"
              >
                <div class="space-y-4">
                  <div class="grid gap-4 sm:grid-cols-2">
                    <.input field={@builder_form[:name]} label="Name" placeholder="My Agent" />
                    <.input
                      field={@builder_form[:description]}
                      label="Description"
                      placeholder="What does this agent do?"
                    />
                  </div>

                  <.inputs_for :let={model_form} field={@builder_form[:model]}>
                    <div class="space-y-4">
                      <div class="grid gap-4 sm:grid-cols-2">
                        <.input
                          field={model_form[:provider]}
                          type="select"
                          label="Provider"
                          options={@model_provider_options}
                        />
                        <.input
                          field={model_form[:id]}
                          type="select"
                          label="Model"
                          options={@model_options}
                        />
                      </div>

                      <div class="grid gap-4 sm:grid-cols-2">
                        <.input
                          field={model_form[:speed]}
                          label="Speed"
                          placeholder="standard"
                        />
                        <div class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-3 py-2.5 text-xs text-[var(--text-muted)]">
                          Provider-qualified models are resolved through LLMDB and stored as an explicit provider plus model ID.
                        </div>
                      </div>

                      <div
                        :if={@resolved_model_spec}
                        id="resolved-model-spec"
                        class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-4 py-3"
                      >
                        <div class="mb-3 flex items-center gap-2">
                          <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                            LLMDB
                          </span>
                          <p class="text-xs font-medium text-[var(--text-strong)]">
                            {resolved_model_name(@resolved_model_spec)}
                          </p>
                        </div>

                        <div class="grid gap-3 sm:grid-cols-2">
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Provider
                            </p>
                            <p class="mt-1 text-xs text-[var(--text-strong)]">
                              {Atom.to_string(@resolved_model_spec.provider)}
                            </p>
                          </div>
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Model ID
                            </p>
                            <p class="mt-1 font-mono text-xs text-[var(--text-strong)]">
                              {@resolved_model_spec.id}
                            </p>
                          </div>
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Family
                            </p>
                            <p class="mt-1 text-xs text-[var(--text-strong)]">
                              {resolved_model_family(@resolved_model_spec)}
                            </p>
                          </div>
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Lifecycle
                            </p>
                            <p class="mt-1 text-xs text-[var(--text-strong)]">
                              {resolved_model_status(@resolved_model_spec)}
                            </p>
                          </div>
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Context Window
                            </p>
                            <p class="mt-1 text-xs text-[var(--text-strong)]">
                              {format_model_limit(
                                get_in(@resolved_model_spec.limits || %{}, [:context])
                              )}
                            </p>
                          </div>
                          <div>
                            <p class="text-[10px] uppercase tracking-[0.12em] text-[var(--text-faint)]">
                              Output Limit
                            </p>
                            <p class="mt-1 text-xs text-[var(--text-strong)]">
                              {format_model_limit(
                                get_in(@resolved_model_spec.limits || %{}, [:output])
                              )}
                            </p>
                          </div>
                        </div>
                      </div>
                    </div>
                  </.inputs_for>

                  <.input
                    field={@builder_form[:system]}
                    type="textarea"
                    rows="4"
                    label="System Prompt"
                    placeholder="You are a helpful agent..."
                  />
                </div>
              </div>
            </section>

            <section class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]">
              <button
                type="button"
                phx-click="toggle_builder_section"
                phx-value-section="capabilities"
                class="flex w-full items-center justify-between p-4 text-left"
              >
                <div>
                  <h2 class="text-sm font-semibold text-[var(--text-strong)]">Capabilities</h2>
                  <p class="mt-0.5 text-[11px] text-[var(--text-muted)]">
                    {length(List.wrap(@draft_params["tools"]))} tools · {length(
                      List.wrap(@draft_params["mcp_servers"])
                    )} MCP servers · {length(List.wrap(@draft_params["skills"]))} skills · {length(
                      List.wrap(@draft_params["callable_agents"])
                    )} callable agents
                  </p>
                </div>
                <.icon
                  name={
                    if(section_open?(@builder_sections, "capabilities"),
                      do: "hero-chevron-down",
                      else: "hero-chevron-right"
                    )
                  }
                  class="size-4 shrink-0 text-[var(--text-muted)]"
                />
              </button>

              <div
                :if={section_open?(@builder_sections, "capabilities")}
                class="space-y-4 border-t border-[var(--border-subtle)] px-4 pb-4 pt-3"
              >
                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <h3 class="text-xs font-medium text-[var(--text-strong)]">Tools</h3>
                    <button
                      type="button"
                      id="add-tool-button"
                      phx-click="add-item"
                      phx-value-section="tools"
                      class="console-button console-button-secondary h-11 min-h-11 px-3 text-xs sm:h-7 sm:min-h-7"
                    >
                      <.icon name="hero-plus" class="size-3" /> Add Tool
                    </button>
                  </div>

                  <div class="space-y-2">
                    <.inputs_for :let={tool_form} field={@builder_form[:tools]} default={[]}>
                      <div class="space-y-2 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-3">
                        <div class="flex items-center justify-between">
                          <div class="flex items-center gap-2">
                            <.status_badge status={field_value(tool_form[:type])} />
                            <p class="text-xs font-medium text-[var(--text-strong)]">
                              Tool {tool_form.index + 1}
                            </p>
                          </div>
                          <button
                            type="button"
                            phx-click="remove-item"
                            phx-value-section="tools"
                            phx-value-index={tool_form.index}
                            class="inline-flex h-11 w-11 min-h-11 min-w-11 items-center justify-center rounded-[8px] text-[var(--text-muted)] transition hover:bg-[var(--panel-bg)] hover:text-[var(--text-strong)] sm:h-7 sm:w-7 sm:min-h-7 sm:min-w-7"
                          >
                            <.icon name="hero-trash" class="size-3.5" />
                          </button>
                        </div>

                        <div class="grid gap-2 sm:grid-cols-2">
                          <.input
                            field={tool_form[:type]}
                            type="select"
                            label="Type"
                            options={[
                              {"Built-in Toolset", "agent_toolset_20260401"},
                              {"MCP Toolset", "mcp_toolset"},
                              {"Custom Tool", "custom"}
                            ]}
                          />

                          <.input
                            :if={field_value(tool_form[:type]) == "mcp_toolset"}
                            field={tool_form[:mcp_server_name]}
                            label="MCP Server"
                            placeholder="server name"
                          />

                          <.input
                            :if={field_value(tool_form[:type]) in ["mcp_toolset", "custom"]}
                            field={tool_form[:permission_policy]}
                            type="select"
                            label="Permission"
                            options={[
                              {"Always Ask", "always_ask"},
                              {"Always Allow", "always_allow"}
                            ]}
                          />

                          <.input
                            :if={field_value(tool_form[:type]) == "custom"}
                            field={tool_form[:name]}
                            label="Tool Name"
                            placeholder="lookup_release"
                          />
                        </div>

                        <.input
                          :if={field_value(tool_form[:type]) == "custom"}
                          field={tool_form[:description]}
                          label="Description"
                          placeholder="Describe what the tool does"
                        />

                        <.input
                          :if={field_value(tool_form[:type]) == "custom"}
                          field={tool_form[:input_schema_json]}
                          type="textarea"
                          rows="2"
                          label="Input Schema JSON"
                        />

                        <.input
                          :if={field_value(tool_form[:type]) == "agent_toolset_20260401"}
                          field={tool_form[:default_config_json]}
                          type="textarea"
                          rows="2"
                          label="Config JSON"
                        />

                        <.input
                          :if={field_value(tool_form[:type]) == "agent_toolset_20260401"}
                          field={tool_form[:configs_json]}
                          type="textarea"
                          rows="2"
                          label="Per-Tool Config JSON"
                        />
                      </div>
                    </.inputs_for>
                  </div>
                </div>

                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <h3 class="text-xs font-medium text-[var(--text-strong)]">MCP Servers</h3>
                    <button
                      type="button"
                      id="add-mcp-server-button"
                      phx-click="add-item"
                      phx-value-section="mcp_servers"
                      class="console-button console-button-secondary h-11 min-h-11 px-3 text-xs sm:h-7 sm:min-h-7"
                    >
                      <.icon name="hero-plus" class="size-3" /> Add
                    </button>
                  </div>

                  <div class="space-y-2">
                    <div
                      :if={List.wrap(@draft_params["mcp_servers"]) == []}
                      class="text-xs text-[var(--text-muted)]"
                    >
                      No MCP servers configured.
                    </div>

                    <.inputs_for :let={server_form} field={@builder_form[:mcp_servers]} default={[]}>
                      <div class="space-y-2 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-3">
                        <div class="flex items-center justify-between">
                          <.input
                            field={server_form[:name]}
                            label="Name"
                            placeholder="Server name"
                          />
                          <button
                            type="button"
                            phx-click="remove-item"
                            phx-value-section="mcp_servers"
                            phx-value-index={server_form.index}
                            class="mt-6 inline-flex h-11 w-11 min-h-11 min-w-11 items-center justify-center rounded-[8px] text-[var(--text-muted)] transition hover:bg-[var(--panel-bg)] hover:text-[var(--text-strong)] sm:h-7 sm:w-7 sm:min-h-7 sm:min-w-7"
                          >
                            <.icon name="hero-trash" class="size-3.5" />
                          </button>
                        </div>
                        <.input field={server_form[:url]} label="URL" placeholder="https://..." />
                      </div>
                    </.inputs_for>
                  </div>
                </div>

                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <h3 class="text-xs font-medium text-[var(--text-strong)]">Skills</h3>
                    <button
                      type="button"
                      id="add-skill-button"
                      phx-click="add-item"
                      phx-value-section="skills"
                      class="console-button console-button-secondary h-11 min-h-11 px-3 text-xs sm:h-7 sm:min-h-7"
                    >
                      <.icon name="hero-plus" class="size-3" /> Add
                    </button>
                  </div>

                  <div class="space-y-2">
                    <div
                      :if={List.wrap(@draft_params["skills"]) == []}
                      class="text-xs text-[var(--text-muted)]"
                    >
                      No skills attached.
                    </div>

                    <.inputs_for :let={skill_form} field={@builder_form[:skills]} default={[]}>
                      <div class="flex items-center gap-2 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-2">
                        <.input
                          field={skill_form[:type]}
                          type="select"
                          label="Type"
                          options={[{"Custom", "custom"}, {"Anthropic", "anthropic"}]}
                        />
                        <.input
                          field={skill_form[:id]}
                          type="select"
                          label="Skill"
                          options={skill_options(@skills)}
                        />
                        <.input
                          field={skill_form[:version]}
                          type="number"
                          min="1"
                          label="v"
                          placeholder="Latest"
                        />
                        <button
                          type="button"
                          phx-click="remove-item"
                          phx-value-section="skills"
                          phx-value-index={skill_form.index}
                          class="mt-6 inline-flex h-11 w-11 min-h-11 min-w-11 items-center justify-center rounded-[8px] text-[var(--text-muted)] transition hover:bg-[var(--panel-bg)] hover:text-[var(--text-strong)] sm:h-7 sm:w-7 sm:min-h-7 sm:min-w-7"
                        >
                          <.icon name="hero-trash" class="size-3.5" />
                        </button>
                      </div>
                    </.inputs_for>
                  </div>
                </div>

                <div>
                  <div class="mb-2 flex items-center justify-between">
                    <h3 class="text-xs font-medium text-[var(--text-strong)]">Callable Agents</h3>
                    <button
                      type="button"
                      id="add-callable-agent-button"
                      phx-click="add-item"
                      phx-value-section="callable_agents"
                      class="console-button console-button-secondary h-11 min-h-11 px-3 text-xs sm:h-7 sm:min-h-7"
                    >
                      <.icon name="hero-plus" class="size-3" /> Add
                    </button>
                  </div>

                  <div class="space-y-2">
                    <div
                      :if={List.wrap(@draft_params["callable_agents"]) == []}
                      class="text-xs text-[var(--text-muted)]"
                    >
                      No callable agents linked.
                    </div>

                    <.inputs_for
                      :let={callable_form}
                      field={@builder_form[:callable_agents]}
                      default={[]}
                    >
                      <div class="flex items-center gap-2 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-2">
                        <.input
                          field={callable_form[:id]}
                          type="select"
                          label="Agent"
                          options={callable_agent_options(@callable_agents, @agent)}
                        />
                        <.input
                          field={callable_form[:version]}
                          type="number"
                          min="1"
                          label="v"
                          placeholder="Latest"
                        />
                        <button
                          type="button"
                          phx-click="remove-item"
                          phx-value-section="callable_agents"
                          phx-value-index={callable_form.index}
                          class="mt-6 inline-flex h-11 w-11 min-h-11 min-w-11 items-center justify-center rounded-[8px] text-[var(--text-muted)] transition hover:bg-[var(--panel-bg)] hover:text-[var(--text-strong)] sm:h-7 sm:w-7 sm:min-h-7 sm:min-w-7"
                        >
                          <.icon name="hero-trash" class="size-3.5" />
                        </button>
                      </div>
                    </.inputs_for>
                  </div>
                </div>
              </div>
            </section>

            <section class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]">
              <button
                type="button"
                phx-click="toggle_builder_section"
                phx-value-section="advanced"
                class="flex w-full items-center justify-between p-4 text-left"
              >
                <div>
                  <h2 class="text-sm font-semibold text-[var(--text-strong)]">Advanced</h2>
                  <p class="mt-0.5 text-[11px] text-[var(--text-muted)]">
                    Metadata and API preview
                  </p>
                </div>
                <.icon
                  name={
                    if(section_open?(@builder_sections, "advanced"),
                      do: "hero-chevron-down",
                      else: "hero-chevron-right"
                    )
                  }
                  class="size-4 shrink-0 text-[var(--text-muted)]"
                />
              </button>

              <div
                :if={section_open?(@builder_sections, "advanced")}
                class="space-y-4 border-t border-[var(--border-subtle)] px-4 pb-4 pt-3"
              >
                <.input
                  field={@builder_form[:metadata_json]}
                  type="textarea"
                  rows="3"
                  label="Metadata JSON"
                />

                <p class="text-[10px] text-[var(--text-muted)]">
                  Recommended filename: <code class="font-mono">{@recommended_filename}</code>
                </p>

                <div class="lg:hidden">
                  <div class="mb-2 flex items-center justify-between">
                    <div class="flex gap-1">
                      <button
                        type="button"
                        phx-click="set_preview_tab"
                        phx-value-tab="json"
                        class={[
                          "rounded px-2 py-1 text-xs font-medium",
                          @preview_tab == "json" && "bg-[var(--text-strong)] text-[var(--panel-bg)]",
                          @preview_tab != "json" && "text-[var(--text-muted)]"
                        ]}
                      >
                        JSON
                      </button>
                      <button
                        type="button"
                        phx-click="set_preview_tab"
                        phx-value-tab="yaml"
                        class={[
                          "rounded px-2 py-1 text-xs font-medium",
                          @preview_tab == "yaml" && "bg-[var(--text-strong)] text-[var(--panel-bg)]",
                          @preview_tab != "yaml" && "text-[var(--text-muted)]"
                        ]}
                      >
                        YAML
                      </button>
                    </div>
                  </div>

                  <pre
                    :if={@preview_tab == "json"}
                    class="console-code-block max-h-[300px] overflow-auto"
                  ><code>{@api_preview}</code></pre>
                  <pre
                    :if={@preview_tab == "yaml"}
                    class="console-code-block max-h-[300px] overflow-auto"
                  ><code>{@yaml_preview}</code></pre>
                </div>
              </div>
            </section>
          </.form>

          <section
            :if={@agent}
            class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]"
          >
            <button
              type="button"
              phx-click="toggle_builder_section"
              phx-value-section="testrun"
              class="flex w-full items-center justify-between p-4 text-left"
            >
              <div>
                <h2 class="text-sm font-semibold text-[var(--text-strong)]">Test Run</h2>
                <p class="mt-0.5 text-[11px] text-[var(--text-muted)]">Launch a test session</p>
              </div>
              <.icon
                name={
                  if(section_open?(@builder_sections, "testrun"),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                  )
                }
                class="size-4 shrink-0 text-[var(--text-muted)]"
              />
            </button>

            <div
              :if={section_open?(@builder_sections, "testrun")}
              class="space-y-4 border-t border-[var(--border-subtle)] px-4 pb-4 pt-3"
            >
              <.form
                for={@runner_form}
                id="agent-runner-form"
                phx-change="validate_runner"
                phx-submit="launch_session"
              >
                <div class="space-y-3">
                  <div class="grid gap-3 sm:grid-cols-2">
                    <.input
                      field={@runner_form[:environment_id]}
                      type="select"
                      label="Environment"
                      prompt="Select environment"
                      options={environment_options(@environments)}
                    />
                    <.input
                      field={@runner_form[:title]}
                      label="Session Title"
                      placeholder="Optional title"
                    />
                  </div>

                  <.input
                    field={@runner_form[:vault_ids]}
                    type="select"
                    multiple
                    label="Vaults"
                    options={vault_options(@vaults)}
                  />

                  <.input
                    field={@runner_form[:prompt]}
                    type="textarea"
                    rows="3"
                    label="Prompt"
                    placeholder="Enter your prompt..."
                  />

                  <div class="flex items-center gap-3">
                    <.button id="runner-submit-button" class="console-button console-button-primary">
                      {if @current_session, do: "Send To Current Session", else: "Launch Session"}
                    </.button>
                    <p :if={@runner_status} class="text-xs text-[var(--text-muted)]">
                      {@runner_status}
                    </p>
                  </div>
                </div>
              </.form>

              <div
                :if={@runner_error}
                id="runner-error"
                class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] p-4 text-sm text-[var(--text-strong)]"
              >
                {@runner_error}
              </div>

              <div
                :if={@runner_notice}
                id="runner-notice"
                class="rounded-[8px] border border-[var(--accent)]/20 bg-[var(--accent-soft)] p-4 text-sm text-[var(--text-strong)]"
              >
                {@runner_notice}
              </div>

              <div id="runner-events" class="space-y-2">
                <div
                  :if={@runner_events == []}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-4 py-10 text-center text-sm text-[var(--text-muted)]"
                >
                  Session events will stream here after you start a run.
                </div>

                <div
                  :for={event <- @runner_events}
                  id={"runner-event-#{event.sequence}"}
                  class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4"
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex items-center gap-2">
                      <span class="console-badge console-badge-neutral px-2 py-1 text-[10px]">
                        {event.type}
                      </span>
                      <span class="font-mono text-[10px] text-[var(--text-muted)]">
                        #{event.sequence}
                      </span>
                    </div>
                    <span class="text-[10px] text-[var(--text-muted)]">
                      {format_timestamp(event.created_at)}
                    </span>
                  </div>
                  <p class="mt-2 whitespace-pre-wrap font-mono text-xs text-[var(--text-strong)]">
                    {event_console_body(event)}
                  </p>
                </div>
              </div>
            </div>
          </section>
        </div>

        <div class="hidden lg:block lg:col-span-2">
          <div class="sticky top-20 space-y-3">
            <section class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]">
              <button
                type="button"
                phx-click="toggle_preview_expanded"
                class="flex w-full items-center justify-between px-4 py-2.5 text-sm font-medium text-[var(--text-strong)]"
              >
                API Preview
                <.icon
                  name={if(@preview_expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
                  class="size-4 text-[var(--text-muted)]"
                />
              </button>

              <div :if={@preview_expanded} class="border-t border-[var(--border-subtle)]">
                <div class="flex items-center justify-between px-4 py-2">
                  <div class="flex gap-1">
                    <button
                      type="button"
                      phx-click="set_preview_tab"
                      phx-value-tab="json"
                      class={[
                        "rounded px-2 py-1 text-xs font-medium",
                        @preview_tab == "json" && "bg-[var(--text-strong)] text-[var(--panel-bg)]",
                        @preview_tab != "json" && "text-[var(--text-muted)]"
                      ]}
                    >
                      JSON
                    </button>
                    <button
                      type="button"
                      phx-click="set_preview_tab"
                      phx-value-tab="yaml"
                      class={[
                        "rounded px-2 py-1 text-xs font-medium",
                        @preview_tab == "yaml" && "bg-[var(--text-strong)] text-[var(--panel-bg)]",
                        @preview_tab != "yaml" && "text-[var(--text-muted)]"
                      ]}
                    >
                      YAML
                    </button>
                  </div>
                </div>

                <div class="px-4 pb-3">
                  <pre
                    id="api-preview"
                    class={[
                      "console-code-block max-h-[400px] overflow-auto",
                      @preview_tab != "json" && "hidden"
                    ]}
                  ><code>{@api_preview}</code></pre>
                  <pre
                    id="yaml-preview"
                    class={[
                      "console-code-block max-h-[400px] overflow-auto",
                      @preview_tab != "yaml" && "hidden"
                    ]}
                  ><code>{@yaml_preview}</code></pre>
                </div>

                <div class="border-t border-[var(--border-subtle)] px-4 py-2">
                  <p class="text-[10px] text-[var(--text-muted)]">
                    Recommended filename: <code class="font-mono">{@recommended_filename}</code>
                  </p>
                </div>
              </div>
            </section>

            <section
              :if={@versions != []}
              class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4"
            >
              <button
                type="button"
                phx-click="toggle_version_history"
                class="flex w-full items-center justify-between text-sm font-medium text-[var(--text-strong)]"
              >
                Version History
                <.icon
                  name={
                    if(@show_version_history, do: "hero-chevron-down", else: "hero-chevron-right")
                  }
                  class="size-4 text-[var(--text-muted)]"
                />
              </button>

              <div :if={@show_version_history} id="version-list" class="mt-3 space-y-2">
                <div
                  :for={version <- @versions}
                  class="flex items-center justify-between rounded-[8px] border border-[var(--border-subtle)] px-3 py-2 text-xs"
                >
                  <span class="font-mono text-[var(--text-strong)]">v{version.version}</span>
                  <span class="text-[var(--text-muted)]">
                    {if version.version == @agent.latest_version.version,
                      do: "Current",
                      else: format_timestamp(version.updated_at)}
                  </span>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp handle_saved_agent(socket, %Agent{} = agent) do
    socket =
      socket
      |> assign_saved_agent(agent)
      |> put_flash(:info, "Agent saved.")

    if socket.assigns.live_action == :new do
      push_navigate(socket, to: ~p"/console/agents/#{agent.id}/edit")
    else
      socket
    end
  end

  defp assign_saved_agent(socket, %Agent{} = agent) do
    actor = socket.assigns.current_user
    {:ok, definition} = AgentDefinition.serialize_definition(agent, actor: actor)
    {:ok, versions} = AgentCatalog.list_versions(agent, actor)

    socket
    |> assign(:agent, agent)
    |> assign(:versions, versions)
    |> assign(:page_title, agent.name)
    |> assign(:builder_errors, [])
    |> assign_builder(draft_from_definition(definition))
  end

  defp ensure_saved_agent(%{assigns: %{agent: %Agent{} = agent}} = socket, _actor),
    do: {:ok, agent, socket}

  defp ensure_saved_agent(%{assigns: %{builder_errors: [_ | _]}} = _socket, _actor) do
    {:error, "Fix the builder validation issues before launching a session."}
  end

  defp ensure_saved_agent(socket, actor) do
    case AgentCatalog.create_from_params(socket.assigns.preview_body, actor) do
      {:ok, %Agent{} = agent} ->
        {:ok, agent, assign_saved_agent(socket, agent)}

      {:error, error} ->
        {:error, error_message(error)}
    end
  end

  defp ensure_runner_session(
         %{assigns: %{current_session: %Session{} = session}} = socket,
         _agent,
         _actor
       ),
       do: {:ok, session, socket}

  defp ensure_runner_session(socket, %Agent{} = agent, actor) do
    with {:ok, %Session{} = session} <- create_session(agent, socket.assigns.runner_params, actor),
         :ok <- SessionStream.subscribe(session.id),
         {:ok, events} <- load_runner_events(session, actor) do
      socket =
        socket
        |> maybe_unsubscribe_current_session()
        |> assign(:current_session, session)
        |> assign(:runner_events, events)
        |> assign(:runner_status, status_from_events(events, session.status))

      {:ok, session, socket}
    else
      {:error, {:conflict, message}} ->
        {:error,
         message <>
           ". The runner always uses the agent workspace, so you need to continue or close the existing active session first."}

      {:error, error} ->
        {:error, error_message(error)}
    end
  end

  defp maybe_append_prompt(_session, prompt, _actor) when prompt in [nil, ""],
    do: {:error, "Prompt is required to run the session."}

  defp maybe_append_prompt(%Session{} = session, prompt, actor) do
    params = %{
      "type" => "user.message",
      "content" => [%{"type" => "text", "text" => prompt}]
    }

    with {:ok, events} <- SessionEventDefinition.normalize_append_payload(params, session, actor),
         {:ok, _appended_events} <- SessionEventLog.append_user_events(session, events, actor) do
      :ok
    end
  end

  defp maybe_run_session(%Session{} = session, socket, actor) do
    if match?(%Task{}, socket.assigns.runner_task) do
      {:error, "The runner is already processing this session."}
    else
      task =
        Task.Supervisor.async_nolink(JidoManagedAgents.TaskSupervisor, fn ->
          result =
            try do
              SessionRuntime.run(session.id, actor)
            rescue
              error -> {:error, error}
            end

          {:session_runtime_result, session.id, result}
        end)

      {:ok, assign(socket, :runner_task, task)}
    end
  end

  defp create_session(%Agent{} = agent, params, actor) do
    session_params =
      %{
        "agent" => agent.id,
        "environment_id" => params["environment_id"],
        "title" => blank_to_nil(params["title"]),
        "vault_ids" => Enum.reject(List.wrap(params["vault_ids"]), &blank?/1)
      }
      |> compact_map()

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

  defp load_runner_events(%Session{} = session, actor) do
    case SessionEventLog.list_events(session, %{limit: @preview_event_limit, after: -1}, actor) do
      {:ok, {events, _has_more}} ->
        {:ok, Enum.filter(events, &SessionStream.session_event_visible?/1)}

      {:error, error} ->
        {:error, error}
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

  defp assign_builder(socket, params, opts \\ []) do
    validate? = Keyword.get(opts, :validate?, false)
    draft_params = normalize_builder_params(params)
    builder_form_params = builder_form_params(draft_params)
    preview_body = build_request_body(draft_params)
    model_provider = selected_model_provider(draft_params)
    resolved_model_spec = resolve_model_spec(draft_params)

    builder_errors =
      if validate? do
        preview_json_errors(draft_params) ++
          validate_builder_preview(preview_body, socket.assigns.current_user)
      else
        []
      end

    socket
    |> assign(:draft_params, draft_params)
    |> assign(:builder_form, to_form(builder_form_params, as: :agent))
    |> assign(:preview_body, preview_body)
    |> assign(:api_preview, Jason.encode!(preview_body, pretty: true))
    |> assign(:yaml_preview, Ymlr.document!(preview_body))
    |> assign(
      :recommended_filename,
      AgentDefinition.recommended_filename(Map.get(preview_body, "name", ""))
    )
    |> assign(:model_provider_options, ModelCatalog.provider_options(model_provider))
    |> assign(
      :model_options,
      ModelCatalog.model_options(model_provider, draft_params["model"]["id"])
    )
    |> assign(:resolved_model_spec, resolved_model_spec)
    |> assign(:builder_errors, builder_errors)
  end

  defp assign_runner(socket, params) do
    runner_params = normalize_runner_params(params, socket.assigns.environments)

    socket
    |> assign(:runner_params, runner_params)
    |> assign(:runner_form, to_form(runner_params, as: :runner))
  end

  defp default_draft do
    %{
      "name" => "",
      "description" => "",
      "system" => "",
      "metadata_json" => "{}",
      "model" => default_model_params(),
      "tools" => [default_tool()],
      "mcp_servers" => [],
      "skills" => [],
      "callable_agents" => []
    }
  end

  defp default_model_params do
    provider = ModelCatalog.default_provider()
    default_model = ModelCatalog.default_model(provider)

    %{
      "provider" => if(provider, do: Atom.to_string(provider), else: ""),
      "id" => if(default_model, do: default_model.id, else: ""),
      "speed" => "standard"
    }
  end

  defp default_tool do
    %{
      "type" => "agent_toolset_20260401",
      "default_config_json" => ~s({"permission_policy":"always_ask"}),
      "configs_json" => "{}",
      "mcp_server_name" => "",
      "permission_policy" => "always_ask",
      "name" => "",
      "description" => "",
      "input_schema_json" => ~s({"type":"object","properties":{}})
    }
  end

  defp default_mcp_server do
    %{"type" => "url", "name" => "", "url" => "", "headers_json" => "{}"}
  end

  defp default_skill do
    %{"type" => "custom", "id" => "", "version" => "", "metadata_json" => "{}"}
  end

  defp default_callable_agent do
    %{"id" => "", "version" => "", "metadata_json" => "{}"}
  end

  defp default_section_item("tools"), do: default_tool()
  defp default_section_item("mcp_servers"), do: default_mcp_server()
  defp default_section_item("skills"), do: default_skill()
  defp default_section_item("callable_agents"), do: default_callable_agent()
  defp default_section_item(_section), do: %{}

  defp default_runner_params(environments) do
    %{
      "environment_id" => default_environment_id(environments),
      "title" => "",
      "vault_ids" => [],
      "prompt" => ""
    }
  end

  defp default_environment_id([first | _rest]), do: first.id
  defp default_environment_id([]), do: ""

  defp normalize_builder_params(params) do
    params = stringify(params)

    %{
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "system" => Map.get(params, "system", ""),
      "metadata_json" => Map.get(params, "metadata_json", "{}"),
      "model" =>
        params
        |> Map.get("model", %{})
        |> stringify()
        |> normalize_model_params(),
      "tools" => normalize_list(Map.get(params, "tools"), &normalize_tool_params/1),
      "mcp_servers" => normalize_list(Map.get(params, "mcp_servers"), &normalize_server_params/1),
      "skills" => normalize_list(Map.get(params, "skills"), &normalize_skill_params/1),
      "callable_agents" =>
        normalize_list(Map.get(params, "callable_agents"), &normalize_callable_agent_params/1)
    }
  end

  defp normalize_tool_params(params) do
    params = stringify(params)

    %{
      "type" => Map.get(params, "type", "agent_toolset_20260401"),
      "default_config_json" => Map.get(params, "default_config_json", "{}"),
      "configs_json" => Map.get(params, "configs_json", "{}"),
      "mcp_server_name" => Map.get(params, "mcp_server_name", ""),
      "permission_policy" => Map.get(params, "permission_policy", "always_ask"),
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "input_schema_json" =>
        Map.get(params, "input_schema_json", ~s({"type":"object","properties":{}}))
    }
  end

  defp normalize_server_params(params) do
    params = stringify(params)

    %{
      "type" => Map.get(params, "type", "url"),
      "name" => Map.get(params, "name", ""),
      "url" => Map.get(params, "url", ""),
      "headers_json" => Map.get(params, "headers_json", "{}")
    }
  end

  defp normalize_skill_params(params) do
    params = stringify(params)

    %{
      "type" => Map.get(params, "type", "custom"),
      "id" => Map.get(params, "id", ""),
      "version" => Map.get(params, "version", ""),
      "metadata_json" => Map.get(params, "metadata_json", "{}")
    }
  end

  defp normalize_callable_agent_params(params) do
    params = stringify(params)

    %{
      "id" => Map.get(params, "id", ""),
      "version" => Map.get(params, "version", ""),
      "metadata_json" => Map.get(params, "metadata_json", "{}")
    }
  end

  defp normalize_model_params(params) do
    provider =
      params
      |> Map.get("provider", "")
      |> ModelCatalog.normalize_provider()
      |> case do
        nil -> ModelCatalog.default_provider()
        provider_id -> provider_id
      end

    model_id =
      params
      |> Map.get("id", "")
      |> normalize_model_id(provider)

    %{
      "provider" => if(provider, do: Atom.to_string(provider), else: ""),
      "id" => model_id || "",
      "speed" => Map.get(params, "speed", "standard")
    }
  end

  defp normalize_model_id(model_id, provider) do
    model_id = blank_to_nil(model_id)

    cond do
      is_nil(provider) ->
        model_id

      match?({:ok, _model}, ModelCatalog.resolve(provider, model_id)) ->
        model_id

      true ->
        case ModelCatalog.default_model(provider) do
          %LLMDB.Model{id: id} -> id
          _other -> model_id
        end
    end
  end

  defp normalize_runner_params(params, environments) do
    params = stringify(params)

    %{
      "environment_id" => Map.get(params, "environment_id", default_environment_id(environments)),
      "title" => Map.get(params, "title", ""),
      "vault_ids" => List.wrap(Map.get(params, "vault_ids", [])),
      "prompt" => Map.get(params, "prompt", "")
    }
  end

  defp build_request_body(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "model" => build_model_body(Map.get(params, "model", %{})),
      "system" => blank_to_nil(Map.get(params, "system")),
      "tools" => Enum.map(Map.get(params, "tools", []), &build_tool_body/1),
      "mcp_servers" => Enum.map(Map.get(params, "mcp_servers", []), &build_mcp_server_body/1),
      "skills" => Enum.map(Map.get(params, "skills", []), &build_skill_body/1),
      "callable_agents" =>
        Enum.map(Map.get(params, "callable_agents", []), &build_callable_agent_body/1),
      "description" => blank_to_nil(Map.get(params, "description")),
      "metadata" => parse_json_field!(Map.get(params, "metadata_json"), %{})
    }
    |> compact_map()
  end

  defp build_model_body(model_params) do
    provider = blank_to_nil(model_params["provider"])
    id = blank_to_nil(model_params["id"])
    speed = blank_to_nil(model_params["speed"]) || "standard"

    %{"id" => id, "speed" => speed}
    |> maybe_put("provider", provider)
    |> compact_map()
  end

  defp build_tool_body(tool_params) do
    case tool_params["type"] do
      "mcp_toolset" ->
        %{
          "type" => "mcp_toolset",
          "mcp_server_name" => blank_to_nil(tool_params["mcp_server_name"]),
          "permission_policy" => blank_to_nil(tool_params["permission_policy"])
        }
        |> compact_map()

      "custom" ->
        %{
          "type" => "custom",
          "name" => blank_to_nil(tool_params["name"]),
          "description" => blank_to_nil(tool_params["description"]),
          "input_schema" => parse_json_field!(tool_params["input_schema_json"], %{}),
          "permission_policy" => blank_to_nil(tool_params["permission_policy"])
        }
        |> compact_map()

      _other ->
        %{
          "type" => "agent_toolset_20260401",
          "default_config" =>
            parse_json_field!(tool_params["default_config_json"], %{
              "permission_policy" => "always_ask"
            }),
          "configs" => parse_json_field!(tool_params["configs_json"], %{})
        }
        |> compact_map()
    end
  end

  defp build_mcp_server_body(server_params) do
    %{
      "type" => blank_to_nil(server_params["type"]) || "url",
      "name" => blank_to_nil(server_params["name"]),
      "url" => blank_to_nil(server_params["url"]),
      "headers" => parse_json_field!(server_params["headers_json"], %{})
    }
    |> compact_map()
  end

  defp build_skill_body(skill_params) do
    %{
      "type" => blank_to_nil(skill_params["type"]) || "custom",
      "skill_id" => blank_to_nil(skill_params["id"]),
      "version" => parse_optional_integer(skill_params["version"]),
      "metadata" => parse_json_field!(skill_params["metadata_json"], %{})
    }
    |> compact_map()
  end

  defp build_callable_agent_body(callable_agent_params) do
    %{
      "type" => "agent",
      "id" => blank_to_nil(callable_agent_params["id"]),
      "version" => parse_optional_integer(callable_agent_params["version"]),
      "metadata" => parse_json_field!(callable_agent_params["metadata_json"], %{})
    }
    |> compact_map()
  end

  defp validate_builder_preview(body, actor) do
    case AgentDefinition.normalize_create_payload(body, actor: actor) do
      {:ok, _payload} -> []
      {:error, {:invalid_request, message}} -> [message]
      {:error, error} -> [error_message(error)]
    end
  end

  defp preview_json_errors(draft_params) do
    tool_errors =
      draft_params["tools"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {tool, index} ->
        case tool["type"] do
          "custom" ->
            json_error_messages([
              {"input_schema_json", tool["input_schema_json"],
               "tools[#{index}].input_schema_json"}
            ])

          "mcp_toolset" ->
            []

          _other ->
            json_error_messages([
              {"default_config_json", tool["default_config_json"],
               "tools[#{index}].default_config_json"},
              {"configs_json", tool["configs_json"], "tools[#{index}].configs_json"}
            ])
        end
      end)

    server_errors =
      draft_params["mcp_servers"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {server, index} ->
        json_error_messages([
          {"headers_json", server["headers_json"], "mcp_servers[#{index}].headers_json"}
        ])
      end)

    skill_errors =
      draft_params["skills"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {skill, index} ->
        json_error_messages([
          {"metadata_json", skill["metadata_json"], "skills[#{index}].metadata_json"}
        ])
      end)

    callable_agent_errors =
      draft_params["callable_agents"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {callable_agent, index} ->
        json_error_messages([
          {"metadata_json", callable_agent["metadata_json"],
           "callable_agents[#{index}].metadata_json"}
        ])
      end)

    tool_errors ++
      server_errors ++
      skill_errors ++
      callable_agent_errors ++
      json_error_messages([{"metadata_json", draft_params["metadata_json"], "metadata_json"}])
  end

  defp json_error_messages(entries) do
    entries
    |> Enum.flat_map(fn {_key, value, label} ->
      case parse_json_field(value, %{}) do
        {:ok, _parsed} -> []
        {:error, message} -> ["#{label} #{message}"]
      end
    end)
  end

  defp draft_from_definition(definition) do
    definition = stringify(definition)

    %{
      "name" => Map.get(definition, "name", ""),
      "description" => Map.get(definition, "description", ""),
      "system" => Map.get(definition, "system", ""),
      "metadata_json" => Jason.encode!(Map.get(definition, "metadata", %{}), pretty: true),
      "model" => model_form_params(Map.get(definition, "model", %{})),
      "tools" => Enum.map(Map.get(definition, "tools", []), &tool_form_params/1),
      "mcp_servers" =>
        Enum.map(Map.get(definition, "mcp_servers", []), &mcp_server_form_params/1),
      "skills" => Enum.map(Map.get(definition, "skills", []), &skill_form_params/1),
      "callable_agents" =>
        Enum.map(Map.get(definition, "callable_agents", []), &callable_agent_form_params/1)
    }
    |> ensure_non_empty("tools", [default_tool()])
  end

  defp model_form_params(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] ->
        %{"provider" => provider, "id" => id, "speed" => "standard"}

      [_single] ->
        %{"provider" => "", "id" => model, "speed" => "standard"}
    end
  end

  defp model_form_params(model) when is_map(model) do
    model = stringify(model)

    %{
      "provider" => Map.get(model, "provider", default_model_params()["provider"]),
      "id" => Map.get(model, "id", default_model_params()["id"]),
      "speed" => Map.get(model, "speed", "standard")
    }
  end

  defp model_form_params(_model), do: default_model_params()

  defp tool_form_params(tool) do
    tool = stringify(tool)

    case Map.get(tool, "type") do
      "mcp_toolset" ->
        default_tool()
        |> Map.put("type", "mcp_toolset")
        |> Map.put("mcp_server_name", Map.get(tool, "mcp_server_name", ""))
        |> Map.put("permission_policy", Map.get(tool, "permission_policy", "always_ask"))

      "custom" ->
        default_tool()
        |> Map.put("type", "custom")
        |> Map.put("name", Map.get(tool, "name", ""))
        |> Map.put("description", Map.get(tool, "description", ""))
        |> Map.put("permission_policy", Map.get(tool, "permission_policy", "always_ask"))
        |> Map.put(
          "input_schema_json",
          Jason.encode!(Map.get(tool, "input_schema", %{}), pretty: true)
        )

      _other ->
        default_tool()
        |> Map.put("type", "agent_toolset_20260401")
        |> Map.put(
          "default_config_json",
          Jason.encode!(Map.get(tool, "default_config", %{}), pretty: true)
        )
        |> Map.put("configs_json", Jason.encode!(Map.get(tool, "configs", %{}), pretty: true))
    end
  end

  defp mcp_server_form_params(server) do
    server = stringify(server)

    %{
      "type" => Map.get(server, "type", "url"),
      "name" => Map.get(server, "name", ""),
      "url" => Map.get(server, "url", ""),
      "headers_json" => Jason.encode!(Map.get(server, "headers", %{}), pretty: true)
    }
  end

  defp skill_form_params(skill) do
    skill = stringify(skill)

    %{
      "type" => Map.get(skill, "type", "custom"),
      "id" => Map.get(skill, "skill_id") || Map.get(skill, "id", ""),
      "version" => to_string(Map.get(skill, "version", "")),
      "metadata_json" => Jason.encode!(Map.get(skill, "metadata", %{}), pretty: true)
    }
  end

  defp callable_agent_form_params(callable_agent) do
    callable_agent = stringify(callable_agent)

    %{
      "id" => Map.get(callable_agent, "id", ""),
      "version" => to_string(Map.get(callable_agent, "version", "")),
      "metadata_json" => Jason.encode!(Map.get(callable_agent, "metadata", %{}), pretty: true)
    }
  end

  defp maybe_unsubscribe_current_session(socket) do
    shutdown_runner_task(socket)

    if session_id = current_session_id(socket) do
      SessionStream.unsubscribe(session_id)
    end

    assign(socket, :runner_task, nil)
  end

  defp shutdown_runner_task(%{assigns: %{runner_task: %Task{} = task}}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp shutdown_runner_task(_socket), do: :ok

  defp current_session_id(socket) do
    case socket.assigns[:current_session] do
      %Session{id: id} -> id
      _other -> nil
    end
  end

  defp merge_runner_events(events, %SessionEvent{} = event) do
    events
    |> Enum.reject(&(&1.sequence == event.sequence))
    |> Kernel.++([event])
    |> Enum.sort_by(& &1.sequence)
  end

  defp status_from_events(events, fallback) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case event.type do
        "session.status_running" -> "running"
        "session.status_idle" -> "idle"
        _other -> nil
      end
    end)
    |> case do
      nil -> to_string(fallback)
      status -> status
    end
  end

  defp status_from_event(%SessionEvent{type: "session.status_running"}, _current), do: "running"
  defp status_from_event(%SessionEvent{type: "session.status_idle"}, _current), do: "idle"
  defp status_from_event(_event, current), do: current

  defp stop_reason_notice(%{"type" => "requires_action"}, _current) do
    "The runtime is waiting on a follow-up user action."
  end

  defp stop_reason_notice(_stop_reason, current), do: current

  defp active_session_notice(%Session{id: id}) do
    "Streaming inline from session #{String.slice(id, 0, 8)}."
  end

  defp environment_options(environments) do
    Enum.map(environments, &{"#{&1.name} (#{networking_label(&1)})", &1.id})
  end

  defp vault_options(vaults) do
    Enum.map(vaults, &{&1.name, &1.id})
  end

  defp skill_options(skills) do
    Enum.map(skills, fn skill ->
      latest = skill.latest_version_number || "latest"
      {"#{skill.name} (#{skill.type}, v#{latest})", skill.id}
    end)
  end

  defp callable_agent_options(callable_agents, current_agent) do
    current_agent_id = if current_agent, do: current_agent.id

    callable_agents
    |> Enum.reject(&(&1.id == current_agent_id))
    |> Enum.map(fn agent ->
      latest = agent.latest_version_number || "latest"
      {"#{agent.name} (v#{latest})", agent.id}
    end)
  end

  defp selected_model_provider(draft_params) do
    draft_params
    |> get_in(["model", "provider"])
    |> ModelCatalog.normalize_provider()
    |> case do
      nil -> ModelCatalog.default_provider()
      provider -> provider
    end
  end

  defp resolve_model_spec(draft_params) do
    provider = selected_model_provider(draft_params)

    case ModelCatalog.resolve(provider, get_in(draft_params, ["model", "id"])) do
      {:ok, model} -> model
      :error -> nil
    end
  end

  defp resolved_model_name(%LLMDB.Model{name: name, id: id}) when is_binary(name) and name != "",
    do: name <> " (" <> id <> ")"

  defp resolved_model_name(%LLMDB.Model{id: id}), do: id

  defp resolved_model_family(%LLMDB.Model{family: family})
       when is_binary(family) and family != "",
       do: family

  defp resolved_model_family(_model), do: "Not specified"

  defp resolved_model_status(%LLMDB.Model{} = model) do
    model
    |> LLMDB.Model.effective_status()
    |> String.capitalize()
  end

  defp format_model_limit(nil), do: "n/a"

  defp format_model_limit(limit) when is_integer(limit) and limit >= 1_000_000 do
    "#{Float.round(limit / 1_000_000, 1)}M"
  end

  defp format_model_limit(limit) when is_integer(limit) and limit >= 1_000 do
    "#{Float.round(limit / 1_000, 1)}K"
  end

  defp format_model_limit(limit) when is_integer(limit), do: Integer.to_string(limit)
  defp format_model_limit(_limit), do: "n/a"

  defp section_open?(sections, section), do: MapSet.member?(sections, section)

  defp networking_label(environment) do
    get_in(environment.config, ["networking", "type"]) || "unknown"
  end

  defp event_console_body(%SessionEvent{type: type, content: content, payload: payload}) do
    text = extract_text_content(content)

    cond do
      text != "" ->
        text

      type in [
        "agent.tool_use",
        "agent.tool_result",
        "agent.mcp_tool_use",
        "agent.custom_tool_use"
      ] ->
        Jason.encode!(payload, pretty: true)

      type == "session.error" ->
        Jason.encode!(payload, pretty: true)

      map_size(payload || %{}) > 0 ->
        Jason.encode!(payload, pretty: true)

      true ->
        "(no payload)"
    end
  end

  defp extract_text_content(content) when is_list(content) do
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

  defp extract_text_content(_content), do: ""

  defp format_timestamp(nil), do: "pending"

  defp format_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp parse_json_field!(value, default) do
    case parse_json_field(value, default) do
      {:ok, parsed} -> parsed
      {:error, _message} -> default
    end
  end

  defp parse_json_field(value, default) when value in [nil, ""], do: {:ok, default}

  defp parse_json_field(value, _default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      {:ok, _other} -> {:error, "JSON input must decode to an object."}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp parse_json_field(_value, _default), do: {:error, "JSON input must be a string."}

  defp parse_optional_integer(value) when value in [nil, ""], do: nil

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 1 -> integer
      _other -> nil
    end
  end

  defp parse_optional_integer(value) when is_integer(value) and value >= 1, do: value
  defp parse_optional_integer(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp blank?(value), do: blank_to_nil(value) in [nil, []]

  defp compact_map(map) do
    Enum.reject(map, fn
      {_key, nil} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_non_empty(map, key, default) do
    if Map.get(map, key, []) == [] do
      Map.put(map, key, default)
    else
      map
    end
  end

  defp builder_form_params(draft_params) do
    Map.merge(draft_params, %{
      "tools" => indexed_form_list(Map.get(draft_params, "tools", [])),
      "mcp_servers" => indexed_form_list(Map.get(draft_params, "mcp_servers", [])),
      "skills" => indexed_form_list(Map.get(draft_params, "skills", [])),
      "callable_agents" => indexed_form_list(Map.get(draft_params, "callable_agents", []))
    })
  end

  defp indexed_form_list(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Map.new(fn {value, index} -> {Integer.to_string(index), value} end)
  end

  defp indexed_form_list(values) when is_map(values), do: values
  defp indexed_form_list(_values), do: %{}

  defp normalize_list(nil, _fun), do: []

  defp normalize_list(values, fun) when is_map(values) do
    values
    |> Enum.sort_by(fn {index, _value} ->
      case Integer.parse(to_string(index)) do
        {integer, _rest} -> integer
        :error -> index
      end
    end)
    |> Enum.map(fn {_index, value} -> fun.(value) end)
  end

  defp normalize_list(values, fun) when is_list(values), do: Enum.map(values, fun)
  defp normalize_list(_values, _fun), do: []

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value), do: value

  defp list_environments(actor) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
  end

  defp list_skills(actor) do
    Skill
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.load(:latest_version_number)
    |> Ash.read!()
  end

  defp list_callable_agents(actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.load(:latest_version_number)
    |> Ash.read!()
  end

  defp list_vaults(actor) do
    Vault
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
  end

  defp field_value(%Phoenix.HTML.FormField{value: value}) when is_binary(value), do: value

  defp field_value(%Phoenix.HTML.FormField{value: value}) when is_atom(value),
    do: Atom.to_string(value)

  defp field_value(%Phoenix.HTML.FormField{value: value}), do: to_string(value || "")

  defp error_message({:invalid_request, message}), do: message
  defp error_message({:conflict, message}), do: message
  defp error_message(:not_found), do: "The requested record was not found."
  defp error_message(%{errors: [error | _rest]}), do: error_message(error)
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)
end
