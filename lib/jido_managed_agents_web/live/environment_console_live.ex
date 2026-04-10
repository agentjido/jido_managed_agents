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
      main_class="px-4 py-8 sm:px-6 lg:px-8"
      container_class="mx-auto max-w-7xl space-y-8"
    >
      <section class="overflow-hidden rounded-[2rem] border border-emerald-200/70 bg-[radial-gradient(circle_at_top_left,_rgba(16,185,129,0.18),_transparent_40%),linear-gradient(135deg,_#052e2b,_#0f172a_58%,_#134e4a)] text-white shadow-2xl shadow-emerald-950/20">
        <div class="grid gap-8 px-6 py-8 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] lg:px-10">
          <div class="space-y-4">
            <p class="text-xs font-semibold uppercase tracking-[0.28em] text-emerald-200">
              Resource Templates
            </p>
            <h1 class="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
              Environments
            </h1>
            <p class="max-w-2xl text-sm leading-6 text-emerald-50/80">
              Define reusable runtime templates, keep networking explicit, and archive old configurations without losing the audit trail for past sessions.
            </p>
            <div class="flex flex-wrap gap-3 pt-2">
              <.console_tab navigate={~p"/console/agents/new"} label="Agents" />
              <.console_tab active label="Environments" />
              <.console_tab navigate={~p"/console/vaults"} label="Vaults" />
            </div>
          </div>
          <div class="grid gap-4 rounded-[1.5rem] border border-white/10 bg-white/5 p-5 text-sm text-emerald-50/90 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
            <.metric_card label="Active" value={active_environment_count(@environments)} />
            <.metric_card label="Archived" value={archived_environment_count(@environments)} />
            <.metric_card
              label="Open Network"
              value={unrestricted_environment_count(@environments)}
            />
          </div>
        </div>
      </section>

      <div class="grid gap-8 xl:grid-cols-[minmax(0,0.92fr)_minmax(0,1.08fr)]">
        <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-emerald-700">
                Catalog
              </p>
              <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                Saved environments
              </h2>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                Templates stay reusable across sessions. Archived templates remain visible but read-only.
              </p>
            </div>
            <.button
              patch={~p"/console/environments"}
              class="rounded-full bg-neutral-900 px-5 text-white hover:bg-neutral-800"
            >
              New template
            </.button>
          </div>

          <div id="environment-list" class="mt-6 space-y-6">
            <div
              :if={active_environments(@environments) == []}
              class="rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-5 py-10 text-center text-sm text-neutral-500"
            >
              No environments yet. Create the first template on the right.
            </div>

            <div :if={active_environments(@environments) != []} class="space-y-3">
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-neutral-500">
                Active
              </p>
              <div
                :for={environment <- active_environments(@environments)}
                class={environment_card_class(environment, @selected_environment)}
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="text-base font-semibold text-neutral-950">{environment.name}</p>
                      <span class={networking_badge_class(environment)}>
                        {networking_label(environment)}
                      </span>
                    </div>
                    <p class="text-sm leading-6 text-neutral-600">
                      {environment.description || "No description yet."}
                    </p>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      Updated {ConsoleHelpers.format_timestamp(environment.updated_at)}
                    </p>
                  </div>
                  <.button
                    patch={~p"/console/environments/#{environment.id}/edit"}
                    class="rounded-full border border-neutral-300 bg-white px-4 text-neutral-800 hover:border-emerald-300 hover:bg-emerald-50"
                  >
                    Edit
                  </.button>
                </div>
              </div>
            </div>

            <div :if={archived_environments(@environments) != []} class="space-y-3">
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-neutral-500">
                Archived
              </p>
              <div
                :for={environment <- archived_environments(@environments)}
                class={environment_card_class(environment, @selected_environment)}
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="text-base font-semibold text-neutral-950">{environment.name}</p>
                      <span class="inline-flex items-center rounded-full bg-neutral-900 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-white">
                        Archived
                      </span>
                    </div>
                    <p class="text-sm leading-6 text-neutral-600">
                      {environment.description || "No description yet."}
                    </p>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      Archived {ConsoleHelpers.format_timestamp(environment.archived_at)}
                    </p>
                  </div>
                  <.button
                    patch={~p"/console/environments/#{environment.id}/edit"}
                    class="rounded-full border border-neutral-300 bg-white px-4 text-neutral-800 hover:border-neutral-400 hover:bg-neutral-50"
                  >
                    View
                  </.button>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-emerald-700">
                Editor
              </p>
              <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                {environment_form_title(@selected_environment)}
              </h2>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                Environments always target the cloud runtime contract. The only mutable runtime switch in v1 is networking.
              </p>
            </div>
            <div
              :if={@selected_environment}
              class="rounded-[1.25rem] border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-600"
            >
              <p class="font-medium text-neutral-900">Template ID</p>
              <p class="mt-1 font-mono text-xs">{@selected_environment.id}</p>
            </div>
          </div>

          <div
            :if={@selected_environment && @selected_environment.archived_at}
            id="environment-read-only-note"
            class="mt-6 rounded-[1.5rem] border border-amber-200 bg-amber-50 px-5 py-4 text-sm leading-6 text-amber-950"
          >
            This environment is archived. The saved template stays available for historical sessions, but edits are locked.
          </div>

          <div
            :if={@environment_errors != []}
            id="environment-error-list"
            class="mt-6 rounded-[1.5rem] border border-rose-200 bg-rose-50 px-5 py-4 text-sm text-rose-900"
          >
            <p class="font-semibold">Environment could not be saved.</p>
            <p :for={error <- @environment_errors} class="mt-2">{error}</p>
          </div>

          <.form
            for={@environment_form}
            id="environment-form"
            class="mt-6 space-y-6"
            phx-change="validate_environment"
            phx-submit="save_environment"
          >
            <div class="grid gap-5 md:grid-cols-2">
              <.input
                field={@environment_form[:name]}
                label="Environment name"
                placeholder="quickstart-env"
                disabled={environment_read_only?(@selected_environment)}
              />
              <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 px-4 py-3">
                <p class="text-sm font-medium text-neutral-900">Runtime type</p>
                <p class="mt-2 inline-flex items-center rounded-full bg-neutral-900 px-3 py-1 text-xs font-semibold uppercase tracking-[0.22em] text-white">
                  cloud
                </p>
                <p class="mt-3 text-sm leading-6 text-neutral-600">
                  Anthropic-compatible container templates map to the `cloud` contract in v1.
                </p>
              </div>
              <.input
                field={@environment_form[:description]}
                type="textarea"
                label="Description"
                rows="4"
                placeholder="Reusable runtime for internal assistants."
                disabled={environment_read_only?(@selected_environment)}
              />
              <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                <.input
                  field={@environment_form[:networking_type]}
                  type="select"
                  label="Networking"
                  options={networking_options()}
                  disabled={environment_read_only?(@selected_environment)}
                />
                <p class="mt-3 text-sm leading-6 text-neutral-600">
                  Restricted keeps network access narrow. Unrestricted is best for agents that need open third-party APIs.
                </p>
              </div>
            </div>

            <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
              <.input
                field={@environment_form[:metadata_json]}
                type="textarea"
                label="Metadata JSON"
                rows="8"
                placeholder={"{\n  \"team\": \"platform\"\n}"}
                disabled={environment_read_only?(@selected_environment)}
              />
              <p class="mt-2 text-sm leading-6 text-neutral-500">
                Optional JSON for labels and downstream routing. The editor expects an object.
              </p>
            </div>

            <div class="flex flex-wrap gap-3">
              <.button
                id="environment-save-button"
                class="rounded-full bg-emerald-600 px-5 text-white hover:bg-emerald-500 disabled:border disabled:border-neutral-200 disabled:bg-neutral-100 disabled:text-neutral-400"
                disabled={environment_read_only?(@selected_environment)}
              >
                {environment_submit_label(@selected_environment)}
              </.button>
              <button
                :if={@selected_environment && !@selected_environment.archived_at}
                id="environment-archive-button"
                type="button"
                phx-click="archive_environment"
                class="rounded-full border border-amber-200 bg-amber-50 px-5 py-2 text-sm font-medium text-amber-950 transition hover:bg-amber-100"
              >
                Archive
              </button>
              <.button
                :if={@selected_environment}
                patch={~p"/console/environments"}
                class="rounded-full border border-neutral-300 bg-white px-5 text-neutral-800 hover:border-neutral-400 hover:bg-neutral-50"
              >
                Start new template
              </.button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric_card(assigns) do
    ~H"""
    <div>
      <p class="text-xs uppercase tracking-[0.2em] text-emerald-100/70">{@label}</p>
      <p class="mt-2 text-3xl font-semibold tracking-tight">{@value}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :navigate, :string, default: nil

  defp console_tab(%{navigate: nil} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full border border-white/15 bg-white/12 px-4 py-2 text-sm font-medium text-white">
      {@label}
    </span>
    """
  end

  defp console_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center rounded-full px-4 py-2 text-sm font-medium transition",
        @active && "border border-white/15 bg-white/12 text-white",
        !@active &&
          "border border-white/10 bg-black/10 text-white/75 hover:bg-white/10 hover:text-white"
      ]}
    >
      {@label}
    </.link>
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

  defp active_environment_count(environments), do: length(active_environments(environments))
  defp archived_environment_count(environments), do: length(archived_environments(environments))

  defp unrestricted_environment_count(environments) do
    environments
    |> active_environments()
    |> Enum.count(&(networking_label(&1) == "unrestricted"))
  end

  defp networking_label(environment) do
    get_in(environment.config || %{}, ["networking", "type"]) || "restricted"
  end

  defp networking_badge_class(environment) do
    case networking_label(environment) do
      "unrestricted" ->
        "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-900"

      _other ->
        "inline-flex items-center rounded-full bg-sky-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-sky-900"
    end
  end

  defp environment_card_class(environment, selected_environment) do
    selected? = selected_environment && selected_environment.id == environment.id

    [
      "rounded-[1.5rem] border p-4 transition",
      if(selected?,
        do: "border-emerald-300 bg-emerald-50/70 shadow-sm shadow-emerald-100",
        else: "border-neutral-200 bg-white hover:border-emerald-200 hover:bg-emerald-50/40"
      )
    ]
  end

  defp environment_form_title(nil), do: "Create environment"
  defp environment_form_title(_environment), do: "Edit environment"

  defp environment_submit_label(nil), do: "Create environment"
  defp environment_submit_label(_environment), do: "Save environment"

  defp environment_saved_message(nil), do: "Environment created."
  defp environment_saved_message(_environment), do: "Environment updated."

  defp environment_read_only?(nil), do: false
  defp environment_read_only?(%Environment{archived_at: %DateTime{}}), do: true
  defp environment_read_only?(%Environment{}), do: false

  defp networking_options do
    [
      {"Restricted", "restricted"},
      {"Unrestricted", "unrestricted"}
    ]
  end
end
