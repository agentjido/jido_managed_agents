defmodule JidoManagedAgentsWeb.Layouts do
  @moduledoc """
  Layouts and shared shell components for the application.
  """

  use JidoManagedAgentsWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map,
    default: nil,
    doc: "the currently authenticated user"

  attr :main_class, :string,
    default: "px-4 py-6 sm:px-6 lg:px-8",
    doc: "optional classes for the main wrapper"

  attr :container_class, :string,
    default: "mx-auto max-w-7xl space-y-6",
    doc: "optional classes for the inner content container"

  attr :section, :atom,
    default: :overview,
    doc: "the active console section"

  attr :pending_count, :integer,
    default: 0,
    doc: "number of sessions awaiting user input"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_items, console_nav_items())

    ~H"""
    <div class="console-shell">
      <aside class="console-sidebar console-lg-up-flex">
        <div class="console-sidebar-inner">
          <.console_brand />

          <nav class="space-y-1">
            <.nav_link
              :for={item <- @nav_items}
              item={item}
              active={item.id == @section}
              pending_count={@pending_count}
            />
          </nav>

          <div class="console-sidebar-footer">
            <div class="space-y-6">
              <div class="space-y-2">
                <p class="text-xs font-medium uppercase tracking-[0.2em] text-[var(--text-faint)]">
                  Appearance
                </p>
                <.theme_toggle />
              </div>

              <div>
                <p class="text-xs font-medium uppercase tracking-[0.2em] text-[var(--text-faint)]">
                  Runtime
                </p>
                <p class="mt-2 text-sm leading-6 text-[var(--text-muted)]">
                  Native Phoenix and LiveView console for managed agents, sessions, environments, and vault-backed credentials.
                </p>
              </div>
            </div>
          </div>
        </div>
      </aside>

      <div
        id="console-mobile-backdrop"
        class="console-mobile-backdrop hidden"
        phx-click={
          JS.hide(to: "#console-mobile-backdrop")
          |> JS.hide(to: "#console-mobile-sheet")
          |> JS.remove_class("overflow-hidden", to: "body")
        }
      />

      <aside id="console-mobile-sheet" class="console-mobile-sheet hidden">
        <div class="flex items-center justify-between border-b border-[var(--border-subtle)] px-4 py-4">
          <.console_brand compact />

          <button
            type="button"
            class="console-icon-button"
            phx-click={
              JS.hide(to: "#console-mobile-backdrop")
              |> JS.hide(to: "#console-mobile-sheet")
              |> JS.remove_class("overflow-hidden", to: "body")
            }
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <nav class="space-y-1 px-3 py-4">
          <.mobile_nav_link
            :for={item <- @nav_items}
            item={item}
            active={item.id == @section}
            pending_count={@pending_count}
          />
        </nav>
      </aside>

      <div class="console-frame">
        <header class="console-topbar">
          <div class="flex items-center gap-3">
            <button
              type="button"
              class="console-icon-button console-mobile-only-inline-flex"
              phx-click={
                JS.show(to: "#console-mobile-backdrop")
                |> JS.show(to: "#console-mobile-sheet")
                |> JS.add_class("overflow-hidden", to: "body")
              }
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>

            <span class="console-environment-chip console-sm-up-inline-flex">local · v0.1.0</span>

            <.link
              :if={@pending_count > 0}
              navigate={~p"/console/sessions"}
              class="console-alert-chip"
            >
              <.icon name="hero-exclamation-circle" class="size-4" />
              {@pending_count} awaiting input
            </.link>
          </div>

          <div class="flex items-center gap-2 sm:gap-3">
            <span :if={@current_user} class="console-user-chip console-md-up-inline-flex">
              {@current_user.email}
            </span>

            <.link
              :if={@current_user}
              href={~p"/sign-out"}
              method="delete"
              class="console-button console-button-secondary"
            >
              Sign out
            </.link>
          </div>
        </header>

        <main class={["console-page", @main_class]}>
          <div class={@container_class}>
            {render_slot(@inner_block)}
          </div>
        </main>

        <nav class="console-bottom-nav">
          <.bottom_nav_link
            :for={item <- bottom_nav_items(@nav_items)}
            item={item}
            active={item.id == @section}
            pending_count={@pending_count}
          />
        </nav>
      </div>

      <DaisyUIComponents.Flash.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Compact light and dark theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="console-theme-toggle" role="group" aria-label="Theme">
      <button
        type="button"
        class="console-theme-option"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        data-theme-toggle
        aria-label="Switch to light theme"
        aria-pressed="false"
        title="Light theme"
      >
        <.icon name="hero-sun" class="size-4" />
      </button>

      <button
        type="button"
        class="console-theme-option"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        data-theme-toggle
        aria-label="Switch to dark theme"
        aria-pressed="false"
        title="Dark theme"
      >
        <.icon name="hero-moon" class="size-4" />
      </button>
    </div>
    """
  end

  attr :compact, :boolean, default: false

  defp console_brand(assigns) do
    ~H"""
    <.link navigate={~p"/console"} class={["console-brand", @compact && "min-w-0"]}>
      <span class="console-brand-mark">
        <img src={~p"/images/logo.svg"} alt="" class="size-5" />
      </span>
      <span :if={!@compact} class="min-w-0">
        <span class="console-brand-label">Jido Managed Agents</span>
        <span class="console-brand-copy">Operator console</span>
      </span>
    </.link>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, required: true
  attr :pending_count, :integer, default: 0

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@item.path} class={["console-nav-link", @active && "console-nav-link-active"]}>
      <span class="flex items-center gap-3">
        <.icon name={@item.icon} class="size-4 shrink-0" />
        <span>{@item.label}</span>
      </span>
      <span
        :if={@item.id == :sessions and @pending_count > 0}
        class="console-nav-count"
      >
        {@pending_count}
      </span>
    </.link>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, required: true
  attr :pending_count, :integer, default: 0

  defp mobile_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      class={["console-mobile-nav-link", @active && "console-mobile-nav-link-active"]}
      phx-click={
        JS.hide(to: "#console-mobile-backdrop")
        |> JS.hide(to: "#console-mobile-sheet")
        |> JS.remove_class("overflow-hidden", to: "body")
      }
    >
      <span class="flex items-center gap-3">
        <.icon name={@item.icon} class="size-5 shrink-0" />
        <span>{@item.label}</span>
      </span>
      <span
        :if={@item.id == :sessions and @pending_count > 0}
        class="console-nav-count"
      >
        {@pending_count}
      </span>
    </.link>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, required: true
  attr :pending_count, :integer, default: 0

  defp bottom_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      class={["console-bottom-link", @active && "console-bottom-link-active"]}
    >
      <span class="relative">
        <.icon name={@item.icon} class="size-5" />
        <span
          :if={@item.id == :sessions and @pending_count > 0}
          class="console-bottom-count"
        >
          {@pending_count}
        </span>
      </span>
      <span>{@item.label}</span>
    </.link>
    """
  end

  defp console_nav_items do
    [
      %{id: :overview, label: "Overview", path: ~p"/console", icon: "hero-squares-2x2"},
      %{id: :agents, label: "Agents", path: ~p"/console/agents", icon: "hero-cpu-chip"},
      %{
        id: :environments,
        label: "Environments",
        path: ~p"/console/environments",
        icon: "hero-server-stack"
      },
      %{id: :vaults, label: "Vaults", path: ~p"/console/vaults", icon: "hero-lock-closed"},
      %{id: :sessions, label: "Sessions", path: ~p"/console/sessions", icon: "hero-bolt"},
      %{id: :api, label: "API Docs", path: ~p"/console/api-docs", icon: "hero-code-bracket"}
    ]
  end

  defp bottom_nav_items(items) do
    Enum.filter(items, &(&1.id in [:overview, :agents, :sessions, :api]))
  end
end
