defmodule JidoManagedAgentsWeb.ApiDocsLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  alias JidoManagedAgents.Accounts
  alias JidoManagedAgents.Accounts.ApiKey
  alias JidoManagedAgentsWeb.ConsoleData
  alias JidoManagedAgentsWeb.ConsoleHelpers

  @resource_order ["Agents", "Sessions", "Vaults", "Environments"]
  @ttl_options [{"7 days", "7"}, {"30 days", "30"}, {"90 days", "90"}]

  @snippets %{
    "Agents" => %{
      method: "POST",
      path: "/v1/agents",
      description: "Create a new agent",
      body: %{
        "name" => "Coding Assistant",
        "description" => "Handles day-to-day engineering tasks.",
        "model" => "claude-sonnet-4-6",
        "system" => "You are a senior software engineer.",
        "tools" => [
          %{
            "type" => "agent_toolset_20260401",
            "configs" => %{
              "read" => %{"permission_policy" => "always_allow"},
              "bash" => %{"permission_policy" => "always_ask"}
            }
          }
        ],
        "mcp_servers" => [
          %{
            "name" => "docs",
            "type" => "url",
            "url" => "https://docs.example.com/mcp"
          }
        ],
        "metadata" => %{"team" => "platform"}
      }
    },
    "Sessions" => %{
      method: "POST",
      path: "/v1/sessions",
      description: "Launch a new session",
      body: %{
        "agent" => %{
          "type" => "agent",
          "id" => "agt_01JABCDEF1234567890",
          "version" => 1
        },
        "environment_id" => "env_01JABCDEF1234567890",
        "title" => "Debug auth flow",
        "vault_ids" => ["vlt_01JABCDEF1234567890"]
      }
    },
    "Vaults" => %{
      method: "POST",
      path: "/v1/vaults",
      description: "Create a vault",
      body: %{
        "display_name" => "Production Secrets",
        "description" => "Credentials for production MCP servers.",
        "display_metadata" => %{"label" => "Primary"},
        "metadata" => %{"external_user_id" => "usr_abc123"}
      }
    },
    "Environments" => %{
      method: "POST",
      path: "/v1/environments",
      description: "Create a runtime template",
      body: %{
        "name" => "Restricted Demo Sandbox",
        "description" => "Reusable sandbox for API-launched sessions.",
        "config" => %{
          "type" => "cloud",
          "networking" => %{"type" => "restricted"}
        },
        "metadata" => %{"team" => "ops"}
      }
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:page_title, "API Docs")
     |> assign(:active_resource, "Agents")
     |> assign(:api_base_url, JidoManagedAgentsWeb.Endpoint.url())
     |> assign(:snippets, @snippets)
     |> assign(:resource_order, @resource_order)
     |> assign(:ttl_options, @ttl_options)
     |> assign(:api_key_form, to_form(%{"ttl_days" => "30"}, as: :api_key))
     |> assign(:generated_api_key, nil)
     |> assign(:api_key_error, nil)
     |> assign(:pending_count, ConsoleData.pending_sessions_count(actor))}
  end

  @impl true
  def handle_event("select_resource", %{"resource" => resource}, socket) do
    next_resource =
      if Map.has_key?(socket.assigns.snippets, resource) do
        resource
      else
        socket.assigns.active_resource
      end

    {:noreply, assign(socket, :active_resource, next_resource)}
  end

  @impl true
  def handle_event("generate_api_key", %{"api_key" => params}, socket) do
    ttl_days = ttl_days(params)

    case create_api_key(socket.assigns.current_user, ttl_days) do
      {:ok, generated_api_key} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "API key generated. Copy it now; the plaintext value is only shown once."
         )
         |> assign(
           :api_key_form,
           to_form(%{"ttl_days" => Integer.to_string(ttl_days)}, as: :api_key)
         )
         |> assign(:generated_api_key, generated_api_key)
         |> assign(:api_key_error, nil)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(
           :api_key_form,
           to_form(%{"ttl_days" => Integer.to_string(ttl_days)}, as: :api_key)
         )
         |> assign(:generated_api_key, nil)
         |> assign(:api_key_error, message)}
    end
  end

  @impl true
  def render(assigns) do
    snippet = Map.fetch!(assigns.snippets, assigns.active_resource)

    assigns = assign(assigns, :snippet, snippet)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_user={@current_user}
      section={:api}
      pending_count={@pending_count}
    >
      <.page_header
        title="API Documentation"
        description="Reference requests for the `/v1` API plus one-click key generation for authenticated console users."
      >
        <:actions>
          <.link href={~p"/api/json/swaggerui"} class="console-button console-button-secondary">
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open Swagger UI
          </.link>
          <.link href="/api/json/open_api" class="console-button console-button-secondary">
            <.icon name="hero-document-text" class="size-4" /> Open OpenAPI JSON
          </.link>
        </:actions>
      </.page_header>

      <section class="mb-6 grid gap-6 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)]">
        <section class="console-panel space-y-4">
          <div class="space-y-1">
            <p class="console-label">Authentication</p>
            <h2 class="text-lg font-semibold text-[var(--text-strong)]">Generate an API key</h2>
            <p class="console-copy max-w-2xl">
              The `/v1` endpoints accept API keys through the <code>x-api-key</code>
              header. Generate one here, then copy it into your client or CLI workflow.
            </p>
          </div>

          <.form
            for={@api_key_form}
            id="api-key-form"
            phx-submit="generate_api_key"
            class="grid gap-4 sm:grid-cols-[minmax(0,14rem)_auto] sm:items-end"
          >
            <.input
              field={@api_key_form[:ttl_days]}
              type="select"
              label="Expiration"
              options={@ttl_options}
            />
            <button type="submit" class="console-button">Generate API key</button>
          </.form>

          <p :if={@api_key_error} id="api-key-error" class="text-sm font-medium text-rose-500">
            {@api_key_error}
          </p>

          <div :if={@generated_api_key} id="generated-api-key" class="space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="space-y-1">
                <p class="console-label">Plaintext key</p>
                <p class="console-list-meta">
                  Expires {ConsoleHelpers.format_timestamp(@generated_api_key.expires_at)}
                </p>
              </div>
              <span class="console-badge console-badge-info px-2 py-1 text-[10px]">Shown once</span>
            </div>
            <pre class="console-code-block"><%= @generated_api_key.plaintext %></pre>
          </div>
        </section>

        <section class="console-panel space-y-4">
          <div class="space-y-1">
            <p class="console-label">Quick start</p>
            <h2 class="text-lg font-semibold text-[var(--text-strong)]">Connect a client</h2>
            <p class="console-copy">
              Swagger UI is useful for shape inspection. For real requests, use the generated key and send it on every `/v1` call.
            </p>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <.link href={~p"/api/json/swaggerui"} class="console-list-button">
              <div class="space-y-1">
                <p class="text-sm font-semibold text-[var(--text-strong)]">Swagger UI</p>
                <p class="console-list-meta">Browse the schema and response models.</p>
              </div>
            </.link>

            <.link href="/api/json/open_api" class="console-list-button">
              <div class="space-y-1">
                <p class="text-sm font-semibold text-[var(--text-strong)]">OpenAPI JSON</p>
                <p class="console-list-meta">Feed the raw spec into codegen or docs tooling.</p>
              </div>
            </.link>
          </div>

          <div class="space-y-2 rounded-lg border border-[var(--panel-border)] bg-[var(--panel-muted)]/70 p-4">
            <p class="console-label">Header format</p>
            <pre class="console-code-block">{header_example(@generated_api_key)}</pre>
          </div>
        </section>
      </section>

      <section class="grid gap-6 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
        <section class="console-panel space-y-3">
          <div class="space-y-1">
            <p class="console-label">Resources</p>
            <h2 class="text-lg font-semibold text-[var(--text-strong)]">Example requests</h2>
          </div>

          <button
            :for={resource <- @resource_order}
            type="button"
            phx-click="select_resource"
            phx-value-resource={resource}
            class={[
              "console-list-button",
              @active_resource == resource && "console-list-button-selected"
            ]}
          >
            <div class="space-y-1">
              <p class="text-sm font-semibold text-[var(--text-strong)]">{resource}</p>
              <p class="console-list-meta">{resource_description(resource)}</p>
            </div>
          </button>
        </section>

        <section class="console-panel space-y-4">
          <div class="space-y-1">
            <p class="console-label">Request</p>
            <h2 class="text-lg font-semibold text-[var(--text-strong)]">{@snippet.description}</h2>
            <p class="console-list-meta">
              <span class="console-badge console-badge-info px-2 py-1 text-[10px]">
                {@snippet.method}
              </span>
              <span class="ml-2 font-mono">{@snippet.path}</span>
            </p>
          </div>

          <div>
            <p class="console-label">Request Body</p>
            <.json_block data={@snippet.body} />
          </div>

          <div>
            <p class="console-label">Example cURL</p>
            <pre class="console-code-block">{curl_command(@snippet, @generated_api_key, @api_base_url)}</pre>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp resource_description("Agents"), do: "Create, version, and manage agent configurations."
  defp resource_description("Sessions"), do: "Launch, stream, and append to agent session runs."
  defp resource_description("Vaults"), do: "Register vaults and secure credentials."
  defp resource_description("Environments"), do: "Manage runtime templates and networking policy."
  defp resource_description(_resource), do: "Example request."

  defp curl_command(snippet, generated_api_key, api_base_url) do
    api_key =
      case generated_api_key do
        %{plaintext: plaintext} when is_binary(plaintext) -> plaintext
        _other -> "YOUR_API_KEY"
      end

    """
    curl -X #{snippet.method} #{api_base_url}#{snippet.path} \\
      -H "x-api-key: #{api_key}" \\
      -H "Content-Type: application/json" \\
      -d '#{Jason.encode!(snippet.body)}'
    """
  end

  defp header_example(generated_api_key) do
    api_key =
      case generated_api_key do
        %{plaintext: plaintext} when is_binary(plaintext) -> plaintext
        _other -> "YOUR_API_KEY"
      end

    "x-api-key: #{api_key}"
  end

  defp ttl_days(%{"ttl_days" => ttl_days}), do: ttl_days(ttl_days)
  defp ttl_days(ttl_days) when is_integer(ttl_days) and ttl_days in [7, 30, 90], do: ttl_days

  defp ttl_days(ttl_days) when is_binary(ttl_days) do
    case Integer.parse(ttl_days) do
      {value, ""} -> ttl_days(value)
      _other -> 30
    end
  end

  defp ttl_days(_params), do: 30

  defp create_api_key(actor, ttl_days) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl_days * 86_400, :second)

    ApiKey
    |> Ash.Changeset.for_create(
      :create,
      %{user_id: actor.id, expires_at: expires_at},
      actor: actor,
      domain: Accounts
    )
    |> Ash.create()
    |> case do
      {:ok, api_key} ->
        {:ok,
         %{
           plaintext: api_key.__metadata__.plaintext_api_key,
           expires_at: api_key.expires_at
         }}

      {:error, error} ->
        {:error, ConsoleHelpers.error_message(error)}
    end
  end
end
