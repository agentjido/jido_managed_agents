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
      |> assign(:show_create_vault, false)
      |> assign(:show_credential_form, false)
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
       |> assign(:show_credential_form, true)
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
         |> assign(:show_credential_form, false)
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
     |> assign(:show_credential_form, false)
     |> assign(:page_title, "Vaults")
     |> assign_credential_form(default_credential_params())}
  end

  @impl true
  def handle_event("validate_vault", %{"vault" => params}, socket) do
    {:noreply, assign_vault_form(socket, params)}
  end

  def handle_event("toggle_create_vault", _params, socket) do
    {:noreply, update(socket, :show_create_vault, &(!&1))}
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

  def handle_event("show_new_credential", _params, %{assigns: %{selected_vault: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("show_new_credential", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_credential, nil)
     |> assign(:show_credential_form, true)
     |> assign_credential_form(default_credential_params())}
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
      section={:vaults}
      main_class="px-4 py-6 sm:px-6 lg:px-8"
      container_class="mx-auto max-w-7xl space-y-6"
    >
      <.page_header
        title="Vaults & Credentials"
        description="Manage write-only credential vaults scoped to MCP server URLs."
      />

      <div class="grid gap-6 lg:grid-cols-5">
        <section class="space-y-3 lg:col-span-2">
          <div class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)]">
            <button
              type="button"
              phx-click="toggle_create_vault"
              class="flex w-full items-center justify-between p-4 text-sm font-medium text-[var(--text-strong)]"
            >
              <span class="flex items-center gap-2">
                <.icon name="hero-plus" class="size-3.5" /> New Vault
              </span>
              <.icon
                name={if(@show_create_vault, do: "hero-chevron-down", else: "hero-chevron-right")}
                class="size-4 text-[var(--text-muted)]"
              />
            </button>

            <div :if={@show_create_vault} class="border-t border-[var(--border-subtle)] p-4">
              <div
                :if={@vault_errors != []}
                id="vault-error-list"
                class="mb-3 rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] px-4 py-3 text-sm text-[var(--text-strong)]"
              >
                <p :for={error <- @vault_errors}>{error}</p>
              </div>

              <.form
                for={@vault_form}
                id="vault-form"
                class="space-y-3"
                phx-change="validate_vault"
                phx-submit="create_vault"
              >
                <.input field={@vault_form[:name]} label="Name" placeholder="My Vault" />
                <.input
                  field={@vault_form[:description]}
                  label="Description"
                  placeholder="What is this vault for?"
                />
                <.input
                  field={@vault_form[:metadata_json]}
                  type="textarea"
                  label="Metadata JSON"
                  rows="2"
                />
                <.button id="vault-save-button" class="console-button console-button-primary">
                  Create Vault
                </.button>
              </.form>
            </div>
          </div>

          <div id="vault-list" class="space-y-2">
            <div :if={@vaults == []}>
              <.empty_state
                title="No vaults"
                description="Create one to start attaching credentials."
              />
            </div>

            <.link
              :for={vault <- @vaults}
              patch={~p"/console/vaults/#{vault.id}"}
              class={[
                "block rounded-[8px] border p-4 transition min-h-[56px]",
                selected_vault?(@selected_vault, vault) &&
                  "border-[var(--session)]/40 bg-[var(--session-soft)]",
                !selected_vault?(@selected_vault, vault) &&
                  "border-[var(--border-subtle)] bg-[var(--panel-bg)] hover:bg-[var(--panel-muted)]"
              ]}
            >
              <div class="flex items-start gap-3">
                <span class="mt-0.5 inline-flex shrink-0 text-[var(--success)]">
                  <.icon name="hero-lock-closed" class="size-4" />
                </span>
                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2">
                    <p class="text-sm font-medium text-[var(--text-strong)]">
                      {vault_display_name(vault)}
                    </p>
                    <span class="ml-auto text-[10px] text-[var(--text-muted)]">
                      {credential_count(vault, @selected_vault, @credentials)}
                      {if credential_count(vault, @selected_vault, @credentials) == 1,
                        do: " cred",
                        else: " creds"}
                    </span>
                  </div>
                  <p :if={vault.description} class="mt-1 truncate text-xs text-[var(--text-muted)]">
                    {vault.description}
                  </p>
                </div>
              </div>
            </.link>
          </div>
        </section>

        <section class="lg:col-span-3">
          <%= if @selected_vault do %>
            <div class="space-y-4">
              <div class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4">
                <div class="mb-2 flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="size-5 text-[var(--success)]" />
                  <h2 class="text-base font-semibold text-[var(--text-strong)]">
                    {vault_display_name(@selected_vault)}
                  </h2>
                </div>
                <p :if={@selected_vault.description} class="mb-2 text-xs text-[var(--text-muted)]">
                  {@selected_vault.description}
                </p>
                <p class="text-[10px] font-mono text-[var(--text-muted)]">ID: {@selected_vault.id}</p>
                <div class="mt-3 rounded-[8px] border border-[var(--success)]/20 bg-[var(--success-soft)] p-3 text-xs text-[var(--success)]">
                  Secrets are write-only. Stored values cannot be retrieved.
                </div>
              </div>

              <div class="rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4">
                <div class="mb-3 flex items-center justify-between gap-3">
                  <h3 class="text-sm font-semibold text-[var(--text-strong)]">Credentials</h3>
                  <button
                    id="show-credential-form-button"
                    type="button"
                    phx-click="show_new_credential"
                    class="console-button console-button-secondary text-xs"
                  >
                    <.icon name="hero-plus" class="size-3" /> Add Credential
                  </button>
                </div>

                <%= if @credentials == [] and !@show_credential_form and is_nil(@selected_credential) do %>
                  <.empty_state
                    title="No credentials"
                    description="Add a credential to map secrets to an MCP server URL."
                  />
                <% else %>
                  <div id="credential-list" class="space-y-2">
                    <.link
                      :for={credential <- @credentials}
                      patch={
                        ~p"/console/vaults/#{@selected_vault.id}/credentials/#{credential.id}/rotate"
                      }
                      class="flex min-h-[56px] items-center justify-between rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-4 transition hover:bg-[var(--panel-bg)]"
                    >
                      <div class="min-w-0 flex-1">
                        <div class="flex items-center gap-2">
                          <span class="text-sm font-medium text-[var(--text-strong)]">
                            {credential_display_name(credential)}
                          </span>
                          <.status_badge status={credential_type(credential_form_params(credential))} />
                        </div>
                        <p class="mt-0.5 truncate font-mono text-[11px] text-[var(--text-muted)]">
                          {credential.mcp_server_url}
                        </p>
                      </div>
                      <.icon
                        name="hero-arrow-path"
                        class="ml-2 size-4 shrink-0 text-[var(--text-muted)]"
                      />
                    </.link>
                  </div>
                <% end %>
              </div>

              <div
                :if={@show_credential_form || @selected_credential}
                class="space-y-3 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-bg)] p-4"
              >
                <h3 class="text-sm font-semibold text-[var(--text-strong)]">
                  {if @selected_credential, do: "Rotate Credential", else: "New Credential"}
                </h3>

                <div
                  :if={@credential_errors != []}
                  id="credential-error-list"
                  class="rounded-[8px] border border-[var(--danger)]/20 bg-[var(--danger-soft)] px-4 py-3 text-sm text-[var(--text-strong)]"
                >
                  <p :for={error <- @credential_errors}>{error}</p>
                </div>

                <div
                  :if={@selected_credential}
                  class="space-y-1 rounded-[8px] border border-[var(--border-subtle)] bg-[var(--panel-muted)] p-3 text-xs"
                >
                  <p class="font-medium text-[var(--text-strong)]">Locked routing fields</p>
                  <p class="text-[var(--text-muted)]">
                    {credential_display_name(@selected_credential)} · {credential_type_label(
                      @selected_credential
                    )} · {@selected_credential.mcp_server_url}
                  </p>
                </div>

                <.form
                  for={@credential_form}
                  id="credential-form"
                  class="space-y-3"
                  phx-change="validate_credential"
                  phx-submit="save_credential"
                >
                  <div :if={is_nil(@selected_credential)} class="space-y-3">
                    <.input
                      field={@credential_form[:display_name]}
                      label="Display Name"
                      placeholder="Alice's Slack"
                    />
                    <.input
                      field={@credential_form[:type]}
                      type="select"
                      label="Credential Type"
                      options={credential_type_options()}
                    />
                    <.input
                      field={@credential_form[:mcp_server_url]}
                      label="MCP Server URL"
                      placeholder="https://mcp.example.com/sse"
                    />
                    <p class="text-[10px] text-[var(--text-muted)]">
                      One credential per MCP server URL per vault.
                    </p>
                  </div>

                  <div :if={credential_type(@credential_form_params) == "static_bearer"}>
                    <.input
                      field={@credential_form[:token]}
                      type="password"
                      label={secret_label(@selected_credential, "Bearer Token")}
                      placeholder={secret_placeholder(@selected_credential, "Enter token")}
                    />
                  </div>

                  <div :if={credential_type(@credential_form_params) == "mcp_oauth"} class="space-y-3">
                    <div class="grid gap-3 sm:grid-cols-2">
                      <.input
                        field={@credential_form[:access_token]}
                        type="password"
                        label={secret_label(@selected_credential, "Access Token")}
                        placeholder={secret_placeholder(@selected_credential, "")}
                      />
                      <.input
                        field={@credential_form[:token_endpoint]}
                        label="Token Endpoint"
                        disabled={not is_nil(@selected_credential)}
                      />
                      <.input
                        field={@credential_form[:client_id]}
                        label="Client ID"
                        disabled={not is_nil(@selected_credential)}
                      />
                      <.input
                        field={@credential_form[:expires_at]}
                        label="Expires At"
                        placeholder="2026-05-01T00:00:00Z"
                      />
                    </div>

                    <details class="text-xs">
                      <summary class="cursor-pointer py-2 text-[var(--text-muted)] hover:text-[var(--text-strong)]">
                        Advanced OAuth fields
                      </summary>
                      <div class="mt-2 grid gap-3 sm:grid-cols-2">
                        <.input
                          field={@credential_form[:refresh_token]}
                          type="password"
                          label={secret_label(@selected_credential, "Refresh Token")}
                          placeholder={secret_placeholder(@selected_credential, "")}
                        />
                        <.input field={@credential_form[:refresh_scope]} label="Scope" />
                        <.input
                          field={@credential_form[:token_endpoint_auth_type]}
                          label="Auth Type"
                          placeholder="client_secret_post"
                        />
                        <.input
                          field={@credential_form[:client_secret]}
                          type="password"
                          label={secret_label(@selected_credential, "Client Secret")}
                          placeholder={secret_placeholder(@selected_credential, "")}
                        />
                      </div>
                    </details>
                  </div>

                  <.input
                    field={@credential_form[:metadata_json]}
                    type="textarea"
                    label="Metadata JSON"
                    rows="2"
                  />

                  <div class="flex flex-wrap gap-2">
                    <.button
                      id="credential-save-button"
                      class="console-button console-button-primary"
                    >
                      {if @selected_credential, do: "Rotate Credential", else: "Create Credential"}
                    </.button>
                    <.link
                      patch={~p"/console/vaults/#{@selected_vault.id}"}
                      class="console-button console-button-secondary"
                    >
                      Cancel
                    </.link>
                  </div>
                </.form>
              </div>
            </div>
          <% else %>
            <.empty_state
              title="No vault selected"
              description="Select a vault from the list or create a new one."
            />
          <% end %>
        </section>
      </div>
    </Layouts.app>
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
    |> assign(:show_create_vault, false)
    |> assign(:show_credential_form, false)
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
    |> assign(:show_credential_form, false)
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

  defp credential_type(form_params) do
    Map.get(form_params, "type", "mcp_oauth")
  end

  defp credential_saved_message(nil), do: "Credential saved."
  defp credential_saved_message(_credential), do: "Credential rotated."

  defp secret_label(nil, label), do: "#{label} (write-only)"
  defp secret_label(_credential, label), do: "#{label} (write-only, leave blank to keep current)"

  defp secret_placeholder(nil, placeholder), do: placeholder
  defp secret_placeholder(_credential, placeholder), do: "#{placeholder} or leave blank"

  defp selected_vault?(nil, _vault), do: false
  defp selected_vault?(%Vault{id: id}, %Vault{id: id}), do: true
  defp selected_vault?(_selected_vault, _vault), do: false

  defp credential_count(vault, %Vault{id: id}, credentials) when vault.id == id,
    do: length(credentials)

  defp credential_count(_vault, _selected_vault, _credentials), do: 0

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(value), do: value

  defp credential_type_options do
    [
      {"MCP OAuth", "mcp_oauth"},
      {"Static bearer token", "static_bearer"}
    ]
  end
end
