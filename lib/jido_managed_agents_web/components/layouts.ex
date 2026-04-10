defmodule JidoManagedAgentsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use JidoManagedAgentsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map,
    default: nil,
    doc: "the currently authenticated user"

  attr :main_class, :string,
    default: "px-4 py-20 sm:px-6 lg:px-8",
    doc: "optional classes for the main wrapper"

  attr :container_class, :string,
    default: "mx-auto max-w-2xl space-y-4",
    doc: "optional classes for the inner content container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 text-base-content">
      <div class="sticky top-0 z-40 border-b border-base-300/80 bg-base-100/90 backdrop-blur">
        <.navbar class="mx-auto max-w-7xl gap-3 px-3 sm:px-6 lg:px-8">
          <:navbar_start class="gap-2">
            <.dropdown class="lg:hidden">
              <label tabindex="0" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-bars-3" class="size-5" />
              </label>
              <.menu
                tabindex="0"
                class="dropdown-content menu-sm z-[60] mt-3 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
              >
                <li><.link navigate={~p"/console/agents/new"}>Agents</.link></li>
                <li><.link navigate={~p"/console/environments"}>Environments</.link></li>
                <li><.link navigate={~p"/console/vaults"}>Vaults</.link></li>
                <li><.link navigate={~p"/console/sessions"}>Sessions</.link></li>
              </.menu>
            </.dropdown>

            <.link navigate={~p"/console/agents/new"} class="flex items-center gap-3">
              <span class="flex size-10 items-center justify-center rounded-box bg-primary/12 ring-1 ring-primary/20">
                <img src={~p"/images/logo.svg"} alt="" class="size-6" />
              </span>
              <span class="min-w-0">
                <span class="block truncate text-sm font-semibold tracking-tight">
                  Managed Agents
                </span>
                <span class="block truncate text-xs text-base-content/60">Runtime console</span>
              </span>
            </.link>
          </:navbar_start>

          <:navbar_center class="hidden flex-1 lg:flex">
            <.menu direction="horizontal" class="rounded-box bg-base-200 p-1 text-sm">
              <li><.link navigate={~p"/console/agents/new"}>Agents</.link></li>
              <li><.link navigate={~p"/console/environments"}>Environments</.link></li>
              <li><.link navigate={~p"/console/vaults"}>Vaults</.link></li>
              <li><.link navigate={~p"/console/sessions"}>Sessions</.link></li>
            </.menu>
          </:navbar_center>

          <:navbar_end class="gap-2">
            <span
              :if={@current_user}
              class="hidden rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-medium text-base-content/70 md:inline-flex"
            >
              {@current_user.email}
            </span>

            <.theme_toggle />

            <.link
              :if={@current_user}
              href={~p"/sign-out"}
              method="delete"
              class="btn btn-sm btn-ghost"
            >
              Sign out
            </.link>
          </:navbar_end>
        </.navbar>
      </div>

      <main class={@main_class}>
        <div class={@container_class}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <DaisyUIComponents.Flash.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
