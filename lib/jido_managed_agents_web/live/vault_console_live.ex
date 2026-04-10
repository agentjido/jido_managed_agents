defmodule JidoManagedAgentsWeb.VaultConsoleLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  require Ash.Query

  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.CredentialDefinition
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Integrations.VaultDefinition
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    vaults = list_vaults(actor)

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:page_title, "Vaults")
      |> assign(:vaults, vaults)
      |> assign(:total_credential_count, count_credentials(actor))
      |> assign(:selected_vault, nil)
      |> assign(:credentials, [])
      |> assign(:selected_credential, nil)
      |> assign(:vault_errors, [])
      |> assign(:credential_errors, [])
      |> assign_vault_form(default_vault_params())
      |> assign_credential_form(default_credential_params())

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"vault_id" => vault_id, "credential_id" => credential_id}, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, %Vault{} = vault} <- fetch_vault(vault_id, actor),
         {:ok, %Credential{} = credential} <- fetch_credential(vault, credential_id, actor) do
      {:noreply,
       socket
       |> assign(:vaults, list_vaults(actor))
       |> assign(:total_credential_count, count_credentials(actor))
       |> assign(:selected_vault, vault)
       |> assign(:credentials, list_credentials(vault, actor))
       |> assign(:selected_credential, credential)
       |> assign(:page_title, "#{vault_display_name(vault)} · Vaults")
       |> assign_credential_form(credential_form_params(credential))}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Vault or credential not found.")
         |> push_navigate(to: ~p"/console/vaults")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
    end
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    actor = socket.assigns.current_user

    case fetch_vault(id, actor) do
      {:ok, %Vault{} = vault} ->
        {:noreply,
         socket
         |> assign(:vaults, list_vaults(actor))
         |> assign(:total_credential_count, count_credentials(actor))
         |> assign(:selected_vault, vault)
         |> assign(:credentials, list_credentials(vault, actor))
         |> assign(:selected_credential, nil)
         |> assign(:page_title, "#{vault_display_name(vault)} · Vaults")
         |> assign_credential_form(default_credential_params())}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Vault not found.")
         |> push_navigate(to: ~p"/console/vaults")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ConsoleHelpers.error_message(error))}
    end
  end

  def handle_params(_params, _uri, socket) do
    actor = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:vaults, list_vaults(actor))
     |> assign(:total_credential_count, count_credentials(actor))
     |> assign(:selected_vault, nil)
     |> assign(:credentials, [])
     |> assign(:selected_credential, nil)
     |> assign(:page_title, "Vaults")
     |> assign_credential_form(default_credential_params())}
  end

  @impl true
  def handle_event("validate_vault", %{"vault" => params}, socket) do
    {:noreply, assign_vault_form(socket, params)}
  end

  def handle_event("create_vault", %{"vault" => params}, socket) do
    actor = socket.assigns.current_user
    socket = assign_vault_form(socket, params)

    with {:ok, payload} <- vault_payload(socket.assigns.vault_form_params),
         {:ok, %Vault{} = vault} <- create_vault(payload, actor) do
      {:noreply, handle_saved_vault(socket, vault)}
    else
      {:error, error} ->
        message = ConsoleHelpers.error_message(error)

        {:noreply,
         socket
         |> assign(:vault_errors, [message])
         |> put_flash(:error, message)}
    end
  end

  def handle_event("validate_credential", %{"credential" => params}, socket) do
    {:noreply, assign_credential_form(socket, params)}
  end

  def handle_event(
        "save_credential",
        %{"credential" => params},
        %{assigns: %{selected_vault: nil}} = socket
      ) do
    socket = assign_credential_form(socket, params)

    {:noreply,
     socket
     |> assign(:credential_errors, ["Select or create a vault before saving credentials."])
     |> put_flash(:error, "Select or create a vault before saving credentials.")}
  end

  def handle_event("save_credential", %{"credential" => params}, socket) do
    actor = socket.assigns.current_user
    socket = assign_credential_form(socket, params)
    mode = if socket.assigns.selected_credential, do: :update, else: :create

    with {:ok, payload} <- credential_payload(socket.assigns.credential_form_params, mode),
         {:ok, %Credential{} = credential} <-
           persist_credential(
             socket.assigns.selected_vault,
             socket.assigns.selected_credential,
             payload,
             actor
           ) do
      {:noreply, handle_saved_credential(socket, credential)}
    else
      {:error, error} ->
        message = ConsoleHelpers.error_message(error)

        {:noreply,
         socket
         |> assign(:credential_errors, [message])
         |> put_flash(:error, message)}
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
      <section class="overflow-hidden rounded-[2rem] border border-sky-200/70 bg-[radial-gradient(circle_at_top_left,_rgba(59,130,246,0.18),_transparent_40%),linear-gradient(135deg,_#0f172a,_#14213d_58%,_#1d4ed8)] text-white shadow-2xl shadow-sky-950/20">
        <div class="grid gap-8 px-6 py-8 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] lg:px-10">
          <div class="space-y-4">
            <p class="text-xs font-semibold uppercase tracking-[0.28em] text-sky-200">
              Secrets And Identity
            </p>
            <h1 class="max-w-3xl text-3xl font-semibold tracking-tight sm:text-4xl">
              Vaults & credentials
            </h1>
            <p class="max-w-2xl text-sm leading-6 text-sky-50/80">
              Register per-user credentials once, match them by MCP server URL, and rotate write-only secrets without falling back to the raw API.
            </p>
            <div class="flex flex-wrap gap-3 pt-2">
              <.console_tab navigate={~p"/console/agents/new"} label="Agents" />
              <.console_tab navigate={~p"/console/environments"} label="Environments" />
              <.console_tab active label="Vaults" />
            </div>
          </div>
          <div class="grid gap-4 rounded-[1.5rem] border border-white/10 bg-white/5 p-5 text-sm text-sky-50/90 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
            <.metric_card label="Vaults" value={length(@vaults)} />
            <.metric_card label="Credentials" value={@total_credential_count} />
            <.metric_card label="Selected" value={length(@credentials)} />
          </div>
        </div>
      </section>

      <div class="grid gap-8 xl:grid-cols-[minmax(0,0.88fr)_minmax(0,1.12fr)]">
        <div class="space-y-8">
          <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.24em] text-sky-700">
                Create vault
              </p>
              <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                New vault
              </h2>
              <p class="mt-1 text-sm leading-6 text-neutral-600">
                Vaults group credentials for one dashboard user. Sessions reference the vault ID, then resolve the matching credential by MCP server URL at runtime.
              </p>
            </div>

            <div
              :if={@vault_errors != []}
              id="vault-error-list"
              class="mt-6 rounded-[1.5rem] border border-rose-200 bg-rose-50 px-5 py-4 text-sm text-rose-900"
            >
              <p class="font-semibold">Vault could not be created.</p>
              <p :for={error <- @vault_errors} class="mt-2">{error}</p>
            </div>

            <.form
              for={@vault_form}
              id="vault-form"
              class="mt-6 space-y-5"
              phx-change="validate_vault"
              phx-submit="create_vault"
            >
              <.input
                field={@vault_form[:name]}
                label="Vault name"
                placeholder="Alice"
              />
              <.input
                field={@vault_form[:description]}
                type="textarea"
                label="Description"
                rows="4"
                placeholder="Third-party service credentials for this user."
              />
              <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                <.input
                  field={@vault_form[:metadata_json]}
                  type="textarea"
                  label="Metadata JSON"
                  rows="7"
                  placeholder={"{\n  \"external_user_id\": \"usr_abc123\"\n}"}
                />
                <p class="mt-2 text-sm leading-6 text-neutral-500">
                  Optional external identifiers or labels. The editor expects a JSON object.
                </p>
              </div>
              <.button
                id="vault-save-button"
                class="rounded-full bg-sky-600 px-5 text-white hover:bg-sky-500"
              >
                Create vault
              </.button>
            </.form>
          </section>

          <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-sky-700">
                  Catalog
                </p>
                <h2 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                  Vault list
                </h2>
                <p class="mt-1 text-sm leading-6 text-neutral-600">
                  Choose a vault to add new credentials or rotate existing ones.
                </p>
              </div>
            </div>

            <div id="vault-list" class="mt-6 space-y-3">
              <div
                :if={@vaults == []}
                class="rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-5 py-10 text-center text-sm text-neutral-500"
              >
                No vaults yet. Create one above to start attaching credentials.
              </div>

              <div :for={vault <- @vaults} class={vault_card_class(vault, @selected_vault)}>
                <div class="flex items-start justify-between gap-4">
                  <div class="space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="text-base font-semibold text-neutral-950">
                        {vault_display_name(vault)}
                      </p>
                      <span class="inline-flex items-center rounded-full bg-sky-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-sky-900">
                        vault
                      </span>
                    </div>
                    <p class="text-sm leading-6 text-neutral-600">
                      {vault.description || "No description yet."}
                    </p>
                    <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                      Updated {ConsoleHelpers.format_timestamp(vault.updated_at)}
                    </p>
                  </div>
                  <.button
                    patch={~p"/console/vaults/#{vault.id}"}
                    class="rounded-full border border-neutral-300 bg-white px-4 text-neutral-800 hover:border-sky-300 hover:bg-sky-50"
                  >
                    Open
                  </.button>
                </div>
              </div>
            </div>
          </section>
        </div>

        <section class="rounded-[2rem] border border-neutral-200 bg-white p-6 shadow-sm">
          <div
            :if={is_nil(@selected_vault)}
            class="flex h-full min-h-[34rem] flex-col items-center justify-center rounded-[1.5rem] border border-dashed border-neutral-300 bg-neutral-50 px-8 text-center"
          >
            <div class="flex size-14 items-center justify-center rounded-full bg-sky-100 text-sky-700">
              <.icon name="hero-key" class="size-7" />
            </div>
            <h2 class="mt-5 text-2xl font-semibold tracking-tight text-neutral-950">
              Select a vault
            </h2>
            <p class="mt-3 max-w-lg text-sm leading-7 text-neutral-600">
              Credential forms stay scoped to one vault so rotation is obvious and the MCP server matching rules stay visible.
            </p>
          </div>

          <div :if={@selected_vault} class="space-y-8">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.24em] text-sky-700">
                  Selected vault
                </p>
                <h2 class="mt-2 text-2xl font-semibold tracking-tight text-neutral-950">
                  {vault_display_name(@selected_vault)}
                </h2>
                <p class="mt-2 max-w-2xl text-sm leading-6 text-neutral-600">
                  {@selected_vault.description ||
                    "Credentials in this vault are matched by MCP server URL at session runtime."}
                </p>
              </div>
              <div class="rounded-[1.25rem] border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-600">
                <p class="font-medium text-neutral-900">Vault ID</p>
                <p class="mt-1 font-mono text-xs">{@selected_vault.id}</p>
              </div>
            </div>

            <div class="rounded-[1.5rem] border border-amber-200 bg-amber-50 px-5 py-4 text-sm leading-6 text-amber-950">
              <div class="flex items-start gap-3">
                <.icon name="hero-lock-closed" class="mt-0.5 size-5 shrink-0" />
                <div>
                  <p class="font-semibold">Write-only secret fields</p>
                  <p class="mt-1">
                    Access tokens, refresh tokens, and client secrets are accepted on save and never rendered back. Leave a secret input blank during rotation to preserve the current stored value.
                  </p>
                </div>
              </div>
            </div>

            <div class="grid gap-6 lg:grid-cols-[minmax(0,0.78fr)_minmax(0,1.22fr)]">
              <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-[0.22em] text-neutral-500">
                      Credentials
                    </p>
                    <h3 class="mt-2 text-lg font-semibold tracking-tight text-neutral-950">
                      Stored routes
                    </h3>
                  </div>
                  <.button
                    :if={@selected_credential}
                    patch={~p"/console/vaults/#{@selected_vault.id}"}
                    class="rounded-full border border-neutral-300 bg-white px-4 text-neutral-800 hover:border-neutral-400 hover:bg-neutral-100"
                  >
                    New credential
                  </.button>
                </div>

                <div id="credential-list" class="mt-5 space-y-3">
                  <div
                    :if={@credentials == []}
                    class="rounded-[1.25rem] border border-dashed border-neutral-300 bg-white px-4 py-8 text-center text-sm text-neutral-500"
                  >
                    No credentials yet for this vault.
                  </div>

                  <div
                    :for={credential <- @credentials}
                    class={credential_card_class(credential, @selected_credential)}
                  >
                    <div class="flex items-start justify-between gap-4">
                      <div class="space-y-2">
                        <div class="flex flex-wrap items-center gap-2">
                          <p class="text-sm font-semibold text-neutral-950">
                            {credential_display_name(credential)}
                          </p>
                          <span class={credential_type_badge_class(credential)}>
                            {credential_type_label(credential)}
                          </span>
                        </div>
                        <p class="break-all font-mono text-xs text-neutral-500">
                          {credential.mcp_server_url}
                        </p>
                        <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                          Updated {ConsoleHelpers.format_timestamp(credential.updated_at)}
                        </p>
                      </div>
                      <.button
                        id={"credential-rotate-button-#{credential.id}"}
                        patch={
                          ~p"/console/vaults/#{@selected_vault.id}/credentials/#{credential.id}/rotate"
                        }
                        class="rounded-full border border-neutral-300 bg-white px-4 text-neutral-800 hover:border-sky-300 hover:bg-sky-100"
                      >
                        Rotate
                      </.button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="space-y-5">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.24em] text-sky-700">
                    {credential_mode_label(@selected_credential)}
                  </p>
                  <h3 class="mt-2 text-xl font-semibold tracking-tight text-neutral-950">
                    {credential_form_title(@selected_credential)}
                  </h3>
                  <p class="mt-1 text-sm leading-6 text-neutral-600">
                    {credential_form_description(@selected_credential)}
                  </p>
                </div>

                <div
                  :if={@credential_errors != []}
                  id="credential-error-list"
                  class="rounded-[1.5rem] border border-rose-200 bg-rose-50 px-5 py-4 text-sm text-rose-900"
                >
                  <p class="font-semibold">Credential could not be saved.</p>
                  <p :for={error <- @credential_errors} class="mt-2">{error}</p>
                </div>

                <div
                  :if={@selected_credential}
                  class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4"
                >
                  <p class="text-xs font-semibold uppercase tracking-[0.22em] text-neutral-500">
                    Locked fields
                  </p>
                  <div class="mt-4 grid gap-4 md:grid-cols-2">
                    <div>
                      <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">Type</p>
                      <p class="mt-1 font-medium text-neutral-900">
                        {credential_type_label(@selected_credential)}
                      </p>
                    </div>
                    <div>
                      <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                        MCP server URL
                      </p>
                      <p class="mt-1 break-all font-mono text-xs text-neutral-700">
                        {@selected_credential.mcp_server_url}
                      </p>
                    </div>
                    <div :if={@selected_credential.type == :mcp_oauth}>
                      <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">
                        Token endpoint
                      </p>
                      <p class="mt-1 break-all font-mono text-xs text-neutral-700">
                        {@selected_credential.token_endpoint || "Not stored"}
                      </p>
                    </div>
                    <div :if={@selected_credential.type == :mcp_oauth}>
                      <p class="text-xs uppercase tracking-[0.18em] text-neutral-400">Client ID</p>
                      <p class="mt-1 break-all font-mono text-xs text-neutral-700">
                        {@selected_credential.client_id || "Not stored"}
                      </p>
                    </div>
                  </div>
                </div>

                <.form
                  for={@credential_form}
                  id="credential-form"
                  class="space-y-5"
                  phx-change="validate_credential"
                  phx-submit="save_credential"
                >
                  <div class="grid gap-5 md:grid-cols-2">
                    <.input
                      field={@credential_form[:display_name]}
                      label="Display name"
                      placeholder="Alice's Slack"
                    />
                    <.input
                      field={@credential_form[:type]}
                      type="select"
                      label="Credential type"
                      options={credential_type_options()}
                      disabled={not is_nil(@selected_credential)}
                    />
                    <.input
                      field={@credential_form[:mcp_server_url]}
                      label="MCP server URL"
                      placeholder="https://mcp.slack.com/mcp"
                      disabled={not is_nil(@selected_credential)}
                    />
                    <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                      <p class="text-sm font-medium text-neutral-900">Routing rule</p>
                      <p class="mt-2 text-sm leading-6 text-neutral-600">
                        One credential route matches one MCP server URL inside this vault.
                      </p>
                    </div>
                  </div>

                  <div
                    :if={credential_type(@credential_form_params) == "static_bearer"}
                    class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4"
                  >
                    <.input
                      field={@credential_form[:token]}
                      type="password"
                      label={secret_label(@selected_credential, "Bearer token")}
                      placeholder={secret_placeholder(@selected_credential, "Enter a bearer token")}
                    />
                    <p class="mt-2 text-sm leading-6 text-neutral-500">
                      Write-only. The stored bearer token is never displayed again after save.
                    </p>
                  </div>

                  <div :if={credential_type(@credential_form_params) == "mcp_oauth"} class="space-y-5">
                    <div class="grid gap-5 md:grid-cols-2">
                      <.input
                        field={@credential_form[:access_token]}
                        type="password"
                        label={secret_label(@selected_credential, "Access token")}
                        placeholder={
                          secret_placeholder(@selected_credential, "Enter a fresh access token")
                        }
                      />
                      <.input
                        field={@credential_form[:expires_at]}
                        label="Expires at"
                        placeholder="2026-05-15T00:00:00Z"
                      />
                    </div>

                    <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                      <p class="text-sm font-medium text-neutral-900">Refresh block</p>
                      <p class="mt-2 text-sm leading-6 text-neutral-600">
                        Token endpoint and client ID are locked after creation. Rotation only updates the secrets and other public surface metadata.
                      </p>
                      <div class="mt-4 grid gap-5 md:grid-cols-2">
                        <.input
                          field={@credential_form[:token_endpoint]}
                          label="Token endpoint"
                          placeholder="https://slack.com/api/oauth.v2.access"
                          disabled={not is_nil(@selected_credential)}
                        />
                        <.input
                          field={@credential_form[:client_id]}
                          label="Client ID"
                          placeholder="1234567890.0987654321"
                          disabled={not is_nil(@selected_credential)}
                        />
                        <.input
                          field={@credential_form[:refresh_token]}
                          type="password"
                          label={secret_label(@selected_credential, "Refresh token")}
                          placeholder={
                            secret_placeholder(@selected_credential, "Enter a refresh token")
                          }
                        />
                        <.input
                          field={@credential_form[:refresh_scope]}
                          label="Scope"
                          placeholder="channels:read chat:write"
                        />
                        <.input
                          field={@credential_form[:token_endpoint_auth_type]}
                          type="select"
                          label="Token endpoint auth"
                          options={token_endpoint_auth_type_options()}
                        />
                        <.input
                          field={@credential_form[:client_secret]}
                          type="password"
                          label={secret_label(@selected_credential, "Client secret")}
                          placeholder={
                            secret_placeholder(@selected_credential, "Enter a client secret")
                          }
                        />
                      </div>
                    </div>
                  </div>

                  <div class="rounded-[1.5rem] border border-neutral-200 bg-neutral-50 p-4">
                    <.input
                      field={@credential_form[:metadata_json]}
                      type="textarea"
                      label="Metadata JSON"
                      rows="7"
                      placeholder={"{\n  \"provider\": \"slack\"\n}"}
                    />
                    <p class="mt-2 text-sm leading-6 text-neutral-500">
                      Optional public metadata returned in safe credential responses. Secret material never appears here.
                    </p>
                  </div>

                  <div class="flex flex-wrap gap-3">
                    <.button
                      id="credential-save-button"
                      class="rounded-full bg-sky-600 px-5 text-white hover:bg-sky-500"
                    >
                      {credential_submit_label(@selected_credential)}
                    </.button>
                    <.button
                      :if={@selected_credential}
                      patch={~p"/console/vaults/#{@selected_vault.id}"}
                      class="rounded-full border border-neutral-300 bg-white px-5 text-neutral-800 hover:border-neutral-400 hover:bg-neutral-50"
                    >
                      Back to new credential
                    </.button>
                  </div>
                </.form>
              </div>
            </div>
          </div>
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
      <p class="text-xs uppercase tracking-[0.2em] text-sky-100/70">{@label}</p>
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

  defp assign_vault_form(socket, params) do
    form_params = normalize_vault_params(params)

    socket
    |> assign(:vault_form_params, form_params)
    |> assign(:vault_form, to_form(form_params, as: :vault))
    |> assign(:vault_errors, vault_validation_errors(form_params))
  end

  defp assign_credential_form(socket, params) do
    form_params = normalize_credential_params(params)

    socket
    |> assign(:credential_form_params, form_params)
    |> assign(:credential_form, to_form(form_params, as: :credential))
    |> assign(:credential_errors, credential_validation_errors(form_params))
  end

  defp default_vault_params do
    %{
      "name" => "",
      "description" => "",
      "metadata_json" => "{}"
    }
  end

  defp normalize_vault_params(params) when is_map(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "description" => Map.get(params, "description", ""),
      "metadata_json" => Map.get(params, "metadata_json", "{}")
    }
  end

  defp vault_validation_errors(form_params) do
    case ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok, _metadata} -> []
      {:error, message} -> ["metadata_json #{message}"]
    end
  end

  defp vault_payload(form_params) do
    with {:ok, metadata} <- ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok,
       %{
         "display_name" => ConsoleHelpers.blank_to_nil(form_params["name"]),
         "description" => ConsoleHelpers.blank_to_nil(form_params["description"]),
         "metadata" => metadata
       }}
    end
  end

  defp create_vault(payload, actor) do
    with {:ok, attrs} <- VaultDefinition.normalize_create_payload(payload) do
      Vault
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :user_id, actor.id),
        actor: actor,
        domain: Integrations
      )
      |> Ash.create()
    end
  end

  defp handle_saved_vault(socket, %Vault{} = vault) do
    actor = socket.assigns.current_user

    socket
    |> assign(:vaults, list_vaults(actor))
    |> assign(:total_credential_count, count_credentials(actor))
    |> assign(:vault_errors, [])
    |> assign_vault_form(default_vault_params())
    |> put_flash(:info, "Vault created.")
    |> push_patch(to: ~p"/console/vaults/#{vault.id}")
  end

  defp default_credential_params do
    %{
      "display_name" => "",
      "type" => "mcp_oauth",
      "mcp_server_url" => "",
      "token" => "",
      "access_token" => "",
      "expires_at" => "",
      "token_endpoint" => "",
      "client_id" => "",
      "refresh_token" => "",
      "refresh_scope" => "",
      "token_endpoint_auth_type" => "client_secret_post",
      "client_secret" => "",
      "metadata_json" => "{}"
    }
  end

  defp normalize_credential_params(params) when is_map(params) do
    %{
      "display_name" => Map.get(params, "display_name", ""),
      "type" => Map.get(params, "type", "mcp_oauth"),
      "mcp_server_url" => Map.get(params, "mcp_server_url", ""),
      "token" => Map.get(params, "token", ""),
      "access_token" => Map.get(params, "access_token", ""),
      "expires_at" => Map.get(params, "expires_at", ""),
      "token_endpoint" => Map.get(params, "token_endpoint", ""),
      "client_id" => Map.get(params, "client_id", ""),
      "refresh_token" => Map.get(params, "refresh_token", ""),
      "refresh_scope" => Map.get(params, "refresh_scope", ""),
      "token_endpoint_auth_type" =>
        Map.get(params, "token_endpoint_auth_type", "client_secret_post"),
      "client_secret" => Map.get(params, "client_secret", ""),
      "metadata_json" => Map.get(params, "metadata_json", "{}")
    }
  end

  defp credential_form_params(%Credential{} = credential) do
    serialized = CredentialDefinition.serialize_credential(credential)
    auth = Map.get(serialized, :auth, %{}) |> stringify_keys()
    refresh = Map.get(auth, "refresh", %{}) |> stringify_keys()
    token_endpoint_auth = Map.get(refresh, "token_endpoint_auth", %{}) |> stringify_keys()

    %{
      "display_name" => Map.get(serialized, :display_name, "") || "",
      "type" => Map.get(auth, "type", "mcp_oauth"),
      "mcp_server_url" => Map.get(auth, "mcp_server_url", ""),
      "token" => "",
      "access_token" => "",
      "expires_at" => Map.get(auth, "expires_at", "") || "",
      "token_endpoint" => Map.get(refresh, "token_endpoint", "") || "",
      "client_id" => Map.get(refresh, "client_id", "") || "",
      "refresh_token" => "",
      "refresh_scope" => Map.get(refresh, "scope", "") || "",
      "token_endpoint_auth_type" => Map.get(token_endpoint_auth, "type", "none"),
      "client_secret" => "",
      "metadata_json" => ConsoleHelpers.pretty_json(Map.get(serialized, :metadata, %{}))
    }
  end

  defp credential_validation_errors(form_params) do
    case ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok, _metadata} -> []
      {:error, message} -> ["metadata_json #{message}"]
    end
  end

  defp credential_payload(form_params, mode) do
    with {:ok, metadata} <- ConsoleHelpers.parse_json_field(form_params["metadata_json"], %{}) do
      {:ok,
       %{
         "display_name" => ConsoleHelpers.blank_to_nil(form_params["display_name"]),
         "metadata" => metadata,
         "auth" => build_credential_auth(form_params, mode)
       }}
    end
  end

  defp build_credential_auth(form_params, :create) do
    case credential_type(form_params) do
      "static_bearer" ->
        %{
          "type" => "static_bearer",
          "mcp_server_url" => ConsoleHelpers.blank_to_nil(form_params["mcp_server_url"]),
          "token" => ConsoleHelpers.blank_to_nil(form_params["token"])
        }
        |> ConsoleHelpers.compact_map()

      _other ->
        %{
          "type" => "mcp_oauth",
          "mcp_server_url" => ConsoleHelpers.blank_to_nil(form_params["mcp_server_url"]),
          "access_token" => ConsoleHelpers.blank_to_nil(form_params["access_token"]),
          "expires_at" => ConsoleHelpers.blank_to_nil(form_params["expires_at"]),
          "refresh" => build_refresh_block(form_params, :create)
        }
        |> ConsoleHelpers.compact_map()
    end
  end

  defp build_credential_auth(form_params, :update) do
    case credential_type(form_params) do
      "static_bearer" ->
        %{
          "type" => "static_bearer",
          "token" => ConsoleHelpers.blank_to_nil(form_params["token"])
        }
        |> ConsoleHelpers.compact_map()

      _other ->
        %{
          "type" => "mcp_oauth",
          "access_token" => ConsoleHelpers.blank_to_nil(form_params["access_token"]),
          "expires_at" => ConsoleHelpers.blank_to_nil(form_params["expires_at"]),
          "refresh" => build_refresh_block(form_params, :update)
        }
        |> ConsoleHelpers.compact_map()
    end
  end

  defp build_refresh_block(form_params, mode) do
    %{}
    |> maybe_put_refresh_creation_field("token_endpoint", form_params["token_endpoint"], mode)
    |> maybe_put_refresh_creation_field("client_id", form_params["client_id"], mode)
    |> ConsoleHelpers.maybe_put(
      "scope",
      ConsoleHelpers.blank_to_nil(form_params["refresh_scope"])
    )
    |> ConsoleHelpers.maybe_put(
      "refresh_token",
      ConsoleHelpers.blank_to_nil(form_params["refresh_token"])
    )
    |> ConsoleHelpers.maybe_put_nested(
      "token_endpoint_auth",
      build_token_endpoint_auth(form_params)
    )
    |> ConsoleHelpers.compact_map()
  end

  defp maybe_put_refresh_creation_field(map, key, value, :create) do
    ConsoleHelpers.maybe_put(map, key, ConsoleHelpers.blank_to_nil(value))
  end

  defp maybe_put_refresh_creation_field(map, _key, _value, :update), do: map

  defp build_token_endpoint_auth(form_params) do
    %{}
    |> ConsoleHelpers.maybe_put(
      "type",
      ConsoleHelpers.blank_to_nil(form_params["token_endpoint_auth_type"])
    )
    |> ConsoleHelpers.maybe_put(
      "client_secret",
      ConsoleHelpers.blank_to_nil(form_params["client_secret"])
    )
    |> ConsoleHelpers.compact_map()
  end

  defp persist_credential(%Vault{} = vault, nil, payload, actor) do
    with {:ok, attrs} <- CredentialDefinition.normalize_create_payload(payload) do
      Credential
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :vault_id, vault.id),
        actor: actor,
        domain: Integrations
      )
      |> Ash.create()
    end
  end

  defp persist_credential(%Vault{}, %Credential{} = credential, payload, actor) do
    with {:ok, attrs} <- CredentialDefinition.normalize_update_payload(payload, credential) do
      credential
      |> Ash.Changeset.for_update(:update, attrs, actor: actor, domain: Integrations)
      |> Ash.update()
    end
  end

  defp handle_saved_credential(socket, %Credential{} = credential) do
    actor = socket.assigns.current_user
    vault = socket.assigns.selected_vault

    socket
    |> assign(:vaults, list_vaults(actor))
    |> assign(:total_credential_count, count_credentials(actor))
    |> assign(:credentials, list_credentials(vault, actor))
    |> assign(:selected_credential, nil)
    |> assign(:credential_errors, [])
    |> assign_credential_form(default_credential_params())
    |> put_flash(:info, credential_saved_message(socket.assigns.selected_credential))
    |> push_patch(to: ~p"/console/vaults/#{credential.vault_id}")
  end

  defp list_vaults(actor) do
    Vault
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!()
  end

  defp count_credentials(actor) do
    Credential
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.read!()
    |> length()
  end

  defp fetch_vault(id, actor) do
    Vault
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Integrations)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Vault{} = vault} -> {:ok, vault}
      {:error, error} -> {:error, error}
    end
  end

  defp list_credentials(vault, actor) do
    Credential
    |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Integrations)
    |> Ash.Query.filter(vault_id == ^vault.id)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!()
  end

  defp fetch_credential(vault, id, actor) do
    Credential
    |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Integrations)
    |> Ash.Query.filter(vault_id == ^vault.id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Credential{} = credential} -> {:ok, credential}
      {:error, error} -> {:error, error}
    end
  end

  defp vault_display_name(vault) do
    serialized = VaultDefinition.serialize_vault(vault)
    serialized.display_name || vault.name
  end

  defp vault_card_class(vault, selected_vault) do
    selected? = selected_vault && selected_vault.id == vault.id

    [
      "rounded-[1.5rem] border p-4 transition",
      if(selected?,
        do: "border-sky-300 bg-sky-50/70 shadow-sm shadow-sky-100",
        else: "border-neutral-200 bg-white hover:border-sky-200 hover:bg-sky-50/40"
      )
    ]
  end

  defp credential_card_class(credential, selected_credential) do
    selected? = selected_credential && selected_credential.id == credential.id

    [
      "rounded-[1.25rem] border p-4 transition",
      if(selected?,
        do: "border-sky-300 bg-sky-100/60 shadow-sm shadow-sky-100",
        else: "border-neutral-200 bg-white hover:border-sky-200 hover:bg-sky-50/50"
      )
    ]
  end

  defp credential_display_name(credential) do
    serialized = CredentialDefinition.serialize_credential(credential)
    serialized[:display_name] || credential.mcp_server_url
  end

  defp credential_type_label(%Credential{type: :static_bearer}), do: "Static bearer"
  defp credential_type_label(%Credential{type: :mcp_oauth}), do: "MCP OAuth"

  defp credential_type_label(form_params) when is_map(form_params) do
    case credential_type(form_params) do
      "static_bearer" -> "Static bearer"
      _other -> "MCP OAuth"
    end
  end

  defp credential_type_badge_class(%Credential{type: :static_bearer}) do
    "inline-flex items-center rounded-full bg-emerald-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-900"
  end

  defp credential_type_badge_class(%Credential{type: :mcp_oauth}) do
    "inline-flex items-center rounded-full bg-violet-100 px-2.5 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-violet-900"
  end

  defp credential_type(form_params) do
    Map.get(form_params, "type", "mcp_oauth")
  end

  defp credential_mode_label(nil), do: "Add credential"
  defp credential_mode_label(_credential), do: "Rotate credential"

  defp credential_form_title(nil), do: "New credential"
  defp credential_form_title(_credential), do: "Rotate credential"

  defp credential_form_description(nil) do
    "Create a safe routing record for one MCP server URL. Secret inputs are stored as provided and never shown again."
  end

  defp credential_form_description(_credential) do
    "Rotation updates secret values and public metadata only. Immutable auth routing fields stay locked so existing session matching does not drift."
  end

  defp credential_submit_label(nil), do: "Save credential"
  defp credential_submit_label(_credential), do: "Rotate credential"

  defp credential_saved_message(nil), do: "Credential saved."
  defp credential_saved_message(_credential), do: "Credential rotated."

  defp secret_label(nil, label), do: "#{label} (write-only)"
  defp secret_label(_credential, label), do: "#{label} (write-only, leave blank to keep current)"

  defp secret_placeholder(nil, placeholder), do: placeholder
  defp secret_placeholder(_credential, placeholder), do: "#{placeholder} or leave blank"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp credential_type_options do
    [
      {"MCP OAuth", "mcp_oauth"},
      {"Static bearer token", "static_bearer"}
    ]
  end

  defp token_endpoint_auth_type_options do
    [
      {"Client secret in POST body", "client_secret_post"},
      {"HTTP Basic auth", "client_secret_basic"},
      {"Public client / none", "none"}
    ]
  end
end
