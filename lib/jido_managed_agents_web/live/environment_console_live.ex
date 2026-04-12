defmodule JidoManagedAgentsWeb.EnvironmentConsoleLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.EnvironmentDefinition
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    environments = list_environments(actor)

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:page_title, "Environments")
      |> assign(:environments, environments)
      |> assign(:environment_filter, "all")
      |> assign(:selected_environment, nil)
      |> assign(:environment_errors, [])
      |> assign_environment_form(default_environment_params())

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    actor = socket.assigns.current_user

    case fetch_environment(id, actor) do
      {:ok, %Environment{} = environment} ->
        {:noreply,
         socket
         |> assign(:environments, list_environments(actor))
         |> assign(:selected_environment, environment)
         |> assign(:page_title, "#{environment.name} · Environments")
         |> assign_environment_form(environment_form_params(environment))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Environment not found.")
         |> push_navigate(to: ~p"/console/environments")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
    end
  end

  def handle_params(_params, _uri, socket) do
    actor = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:environments, list_environments(actor))
     |> assign(:selected_environment, nil)
     |> assign(:page_title, "Environments")
     |> assign_environment_form(default_environment_params())}
  end

  @impl true
  def handle_event("validate_environment", %{"environment" => params}, socket) do
    {:noreply, assign_environment_form(socket, params)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket)
      when filter in ["all", "active", "archived"] do
    {:noreply, assign(socket, :environment_filter, filter)}
  end

  def handle_event("save_environment", %{"environment" => params}, socket) do
    actor = socket.assigns.current_user
    socket = assign_environment_form(socket, params)

    with {:ok, payload} <- environment_payload(socket.assigns.environment_form_params),
         {:ok, %Environment{} = environment} <-
           persist_environment(socket.assigns.selected_environment, payload, actor) do
      {:noreply, handle_saved_environment(socket, environment)}
    else
      {:error, error} ->
        message = ConsoleHelpers.error_message(error)

        {:noreply,
         socket
         |> assign(:environment_errors, [message])
         |> put_flash(:error, message)}
    end
  end

  def handle_event(
        "archive_environment",
        _params,
        %{assigns: %{selected_environment: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("archive_environment", _params, socket) do
    actor = socket.assigns.current_user

    case archive_environment(socket.assigns.selected_environment, actor) do
      {:ok, %Environment{} = environment} ->
        {:noreply,
         socket
         |> assign(:environments, list_environments(actor))
         |> assign(:selected_environment, environment)
         |> assign_environment_form(environment_form_params(environment))
         |> put_flash(:info, "Environment archived.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:environments}
      main_class="px-4 py-6 sm:px-6 lg:px-8"
      container_class="mx-auto max-w-7xl space-y-6"
    >
      <.page_header
        title="Environments"
        description="Manage reusable runtime templates for agent sessions."
      />

      <div class="flex items-center gap-4 text-xs text-[var(--text-muted)]">
        <span>{active_environment_count(@environments)} active</span>
        <span class="text-[var(--border-strong)]">·</span>
        <span>{archived_environment_count(@environments)} archived</span>
      </div>

      <div class="grid gap-6 lg:grid-cols-5">
        <section class="space-y-3 lg:col-span-2">
          <div class="flex items-center gap-2">
            <button
              :for={filter <- environment_filters()}
              type="button"
              phx-click="set_filter"
              phx-value-filter={filter.value}
              class={[
                "console-button px-3 text-xs",
                if(@environment_filter == filter.value,
                  do: "console-button-primary",
                  else: "console-button-secondary"
                )
              ]}
            >
              {filter.label}
            </button>

            <.link
              patch={~p"/console/environments"}
              class="console-button console-button-ghost ml-auto px-3 text-xs"
            >
              <.icon name="hero-plus" class="size-3" /> New
            </.link>
          </div>

          <div :if={filtered_environments(@environments, @environment_filter) == []}>
            <.empty_state
              title="No environments"
              description="Create a template or widen the filter."
            />
          </div>

          <.link
            :for={environment <- filtered_environments(@environments, @environment_filter)}
            id={"environment-card-#{environment.id}"}
            patch={~p"/console/environments/#{environment.id}/edit"}
            class={[
              "block rounded-[8px] border p-4 text-left transition min-h-[56px]",
              selected_environment?(@selected_environment, environment) &&
                "border-[var(--session)]/40 bg-[var(--session-soft)]",
              !selected_environment?(@selected_environment, environment) &&
                "border-[var(--border-subtle)] bg-[var(--panel-bg)] hover:bg-[var(--panel-muted)]"
            ]}
          >
            <div class="flex items-start gap-3">
              <span class="mt-0.5 inline-flex shrink-0 text-[var(--session)]">
                <.icon name="hero-server-stack" class="size-4" />
              </span>

              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="text-sm font-medium text-[var(--text-strong)]">{environment.name}</p>
                  <.status_badge :if={environment.archived_at} status="archived" size="small" />
                </div>

                <div class="mt-1 flex flex-wrap items-center gap-2">
                  <.status_badge status={networking_label(environment)} size="small" />
                  <span class="text-[10px] text-[var(--text-muted)]">
                    {ConsoleHelpers.format_timestamp(environment.updated_at)}
                  </span>
                </div>

                <p :if={environment.description} class="mt-1 text-xs text-[var(--text-muted)]">
                  {environment.description}
                </p>
              </div>
            </div>
          </.link>
        </section>

        <section class="lg:col-span-3">
          <div class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-5 space-y-4">
            <div
              :if={@selected_environment && @selected_environment.archived_at}
              id="environment-read-only-note"
              class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-3 py-2 text-xs text-[var(--text-muted)]"
            >
              This environment is archived and read-only.
            </div>

            <h2 class="text-sm font-semibold text-[var(--text-strong)]">
              {if @selected_environment do
                if @selected_environment.archived_at,
                  do: @environment_form_params["name"],
                  else: "Edit: #{@environment_form_params["name"]}"
              else
                "New Environment"
              end}
            </h2>

            <div
              :if={@environment_errors != []}
              id="environment-error-list"
              class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] px-4 py-3 text-sm text-[var(--text-strong)]"
            >
              <p :for={error <- @environment_errors}>{error}</p>
            </div>

            <.form
              for={@environment_form}
              id="environment-form"
              class="space-y-4"
              phx-change="validate_environment"
              phx-submit="save_environment"
            >
              <div>
                <.input
                  field={@environment_form[:name]}
                  label="Name"
                  placeholder="Environment name"
                  disabled={environment_read_only?(@selected_environment)}
                />
              </div>

              <div>
                <.input
                  field={@environment_form[:description]}
                  type="textarea"
                  label="Description"
                  rows="2"
                  placeholder="What is this environment for?"
                  disabled={environment_read_only?(@selected_environment)}
                />
              </div>

              <div>
                <label class="mb-1 block text-sm font-medium leading-6 text-zinc-950 dark:text-zinc-100">
                  Runtime Type
                </label>
                <input
                  type="text"
                  value="cloud"
                  disabled
                  class="mt-1 block w-full rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] px-3 py-2.5 text-sm text-[var(--text-muted)] outline-none"
                />
              </div>

              <div>
                <.input
                  field={@environment_form[:networking_type]}
                  type="select"
                  label="Networking"
                  options={networking_options()}
                  disabled={environment_read_only?(@selected_environment)}
                />
                <p class="mt-1.5 text-[11px] text-[var(--text-muted)]">
                  <%= if @environment_form_params["networking_type"] == "restricted" do %>
                    No outbound network. Safe for untrusted configs.
                  <% else %>
                    Full outbound access. Use with trusted configs only.
                  <% end %>
                </p>
              </div>

              <div>
                <.input
                  field={@environment_form[:metadata_json]}
                  type="textarea"
                  label="Metadata JSON"
                  rows="3"
                  disabled={environment_read_only?(@selected_environment)}
                />
              </div>

              <div :if={!environment_read_only?(@selected_environment)} class="flex flex-wrap gap-2">
                <.button
                  id="environment-save-button"
                  class="console-button console-button-primary"
                >
                  {if @selected_environment, do: "Save Template", else: "Create Template"}
                </.button>

                <button
                  :if={@selected_environment}
                  id="environment-archive-button"
                  type="button"
                  phx-click="archive_environment"
                  class="console-button console-button-secondary"
                >
                  Archive
                </button>
              </div>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp assign_environment_form(socket, params) do
    form_params = normalize_environment_params(params)

    socket
    |> assign(:environment_form_params, form_params)
    |> assign(:environment_form, to_form(form_params, as: :environment))
    |> assign(:environment_errors, environment_validation_errors(form_params))
  end

  defp normalize_environment_params(params) when is_map(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "networking_type" => Map.get(params, "networking_type", "restricted"),
      "metadata_json" => Map.get(params, "metadata_json", "{}")
    }
  end

  defp default_environment_params do
    %{
      "name" => "",
      "description" => "",
      "networking_type" => "restricted",
      "metadata_json" => "{}"
    }
  end

  defp environment_form_params(%Environment{} = environment) do
    %{
      "name" => environment.name || "",
      "description" => environment.description || "",
      "networking_type" =>
        get_in(environment.config || %{}, ["networking", "type"]) || "restricted",
      "metadata_json" => ConsoleHelpers.pretty_json(environment.metadata || %{})
    }
  end

  defp environment_validation_errors(form_params) do
    case ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok, _metadata} -> []
      {:error, message} -> ["metadata_json #{message}"]
    end
  end

  defp environment_payload(form_params) do
    with {:ok, metadata} <- ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok,
       %{
         "name" => ConsoleHelpers.blank_to_nil(form_params["name"]),
         "description" => ConsoleHelpers.blank_to_nil(form_params["description"]),
         "config" => %{
           "type" => "cloud",
           "networking" => %{
             "type" => ConsoleHelpers.blank_to_nil(form_params["networking_type"]) || "restricted"
           }
         },
         "metadata" => metadata
       }}
    end
  end

  defp persist_environment(nil, payload, actor) do
    with {:ok, attrs} <- EnvironmentDefinition.normalize_create_payload(payload) do
      Environment
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :user_id, actor.id),
        actor: actor,
        domain: Agents
      )
      |> Ash.create()
    end
  end

  defp persist_environment(%Environment{} = environment, payload, actor) do
    with {:ok, attrs} <- EnvironmentDefinition.normalize_update_payload(payload, environment) do
      environment
      |> Ash.Changeset.for_update(:update, attrs, actor: actor, domain: Agents)
      |> Ash.update()
    end
  end

  defp archive_environment(%Environment{archived_at: %DateTime{}} = environment, _actor),
    do: {:ok, environment}

  defp archive_environment(%Environment{} = environment, actor) do
    environment
    |> Ash.Changeset.for_update(:archive, %{}, actor: actor, domain: Agents)
    |> Ash.update()
  end

  defp handle_saved_environment(socket, %Environment{} = environment) do
    actor = socket.assigns.current_user

    socket
    |> assign(:environments, list_environments(actor))
    |> assign(:environment_errors, [])
    |> put_flash(:info, environment_saved_message(socket.assigns.selected_environment))
    |> push_patch(to: ~p"/console/environments/#{environment.id}/edit")
  end

  defp list_environments(actor) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!()
  end

  defp fetch_environment(id, actor) do
    Environment
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Agents)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Environment{} = environment} -> {:ok, environment}
      {:error, error} -> {:error, error}
    end
  end

  defp active_environments(environments) do
    Enum.filter(environments, &is_nil(&1.archived_at))
  end

  defp archived_environments(environments) do
    Enum.filter(environments, &match?(%DateTime{}, &1.archived_at))
  end

  defp filtered_environments(environments, "active"), do: active_environments(environments)
  defp filtered_environments(environments, "archived"), do: archived_environments(environments)
  defp filtered_environments(environments, _filter), do: environments

  defp active_environment_count(environments), do: length(active_environments(environments))
  defp archived_environment_count(environments), do: length(archived_environments(environments))

  defp networking_label(environment) do
    get_in(environment.config || %{}, ["networking", "type"]) || "restricted"
  end

  defp environment_saved_message(nil), do: "Environment created."
  defp environment_saved_message(_environment), do: "Environment updated."

  defp environment_read_only?(nil), do: false
  defp environment_read_only?(%Environment{archived_at: %DateTime{}}), do: true
  defp environment_read_only?(%Environment{}), do: false

  defp selected_environment?(nil, _environment), do: false
  defp selected_environment?(%Environment{id: id}, %Environment{id: id}), do: true
  defp selected_environment?(_selected, _environment), do: false

  defp networking_options do
    [
      {"Restricted", "restricted"},
      {"Unrestricted", "unrestricted"}
    ]
  end

  defp environment_filters do
    [
      %{label: "All", value: "all"},
      %{label: "Active", value: "active"},
      %{label: "Archived", value: "archived"}
    ]
  end
end
