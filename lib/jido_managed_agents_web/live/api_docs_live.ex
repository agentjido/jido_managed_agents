defmodule JidoManagedAgentsWeb.ApiDocsLive do
  use JidoManagedAgentsWeb, :live_view

  on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}

  alias JidoManagedAgentsWeb.ConsoleData

  @snippets %{
    "Agents" => %{
      method: "POST",
      path: "/v1/agents",
      description: "Create a new agent",
      body: %{
        name: "Coding Assistant",
        model: %{provider: "anthropic", model_id: "claude-sonnet-4-20250514"},
        system_prompt: "You are a senior software engineer."
      }
    },
    "Sessions" => %{
      method: "POST",
      path: "/v1/sessions",
      description: "Launch a new session",
      body: %{
        agent_id: "agt_01",
        environment_id: "env_01",
        title: "Debug auth flow",
        vault_ids: ["vlt_01"]
      }
    },
    "Vaults" => %{
      method: "POST",
      path: "/v1/vaults",
      description: "Create a vault",
      body: %{
        name: "Production Secrets",
        description: "Credentials for production MCP servers"
      }
    },
    "Environments" => %{
      method: "POST",
      path: "/v1/environments",
      description: "Create a runtime template",
      body: %{
        name: "Restricted Demo Sandbox",
        runtime: "cloud",
        networking: "restricted"
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
     |> assign(:pending_count, ConsoleData.pending_sessions_count(actor))}
  end

  @impl true
  def handle_event("select_resource", %{"resource" => resource}, socket) do
    {:noreply, assign(socket, :active_resource, resource)}
  end

  @impl true
  def render(assigns) do
    snippet = Map.fetch!(@snippets, assigns.active_resource)

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
        description="Anthropic-shaped `/v1` endpoints for agents, sessions, environments, and vault-backed credentials."
      >
        <:actions>
          <.link href={~p"/api/json/swaggerui"} class="console-button console-button-secondary">
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open Swagger UI
          </.link>
        </:actions>
      </.page_header>

      <section class="grid gap-6 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
        <section class="console-panel space-y-3">
          <div class="space-y-1">
            <p class="console-label">Resources</p>
            <h2 class="text-lg font-semibold text-[var(--text-strong)]">Example requests</h2>
          </div>

          <button
            :for={resource <- Map.keys(@snippets)}
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
            <pre class="console-code-block">{curl_command(@snippet)}</pre>
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

  defp curl_command(snippet) do
    """
    curl -X #{snippet.method} http://localhost:4000#{snippet.path} \\
      -H "Content-Type: application/json" \\
      -d '#{Jason.encode!(snippet.body)}'
    """
  end
end
