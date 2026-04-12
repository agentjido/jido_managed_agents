defmodule JidoManagedAgentsWeb.ConsoleComponents do
  @moduledoc false

  use Phoenix.Component

  import JidoManagedAgentsWeb.CoreComponents

  alias JidoManagedAgentsWeb.ConsoleHelpers

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="console-page-header">
      <div class="space-y-2">
        <h1 class="console-title">{@title}</h1>
        <p :if={@description} class="console-copy max-w-3xl">{@description}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-3">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: nil
  attr :accent, :string, default: nil

  def kpi_card(assigns) do
    ~H"""
    <div class="console-kpi">
      <div class="flex items-center justify-between gap-3">
        <p class="console-kpi-label">{@label}</p>
        <.icon
          :if={@icon}
          name={@icon}
          class={["size-4 text-[var(--text-muted)]", @accent]}
        />
      </div>
      <p class={["console-kpi-value", @accent]}>{@value}</p>
    </div>
    """
  end

  attr :status, :any, required: true
  attr :size, :string, default: "default"

  def status_badge(assigns) do
    status = normalize_status(assigns.status)

    assigns =
      assigns
      |> assign(:label, badge_label(status))
      |> assign(:badge_class, badge_class(status, assigns.size))

    ~H"""
    <span class={@badge_class}>{@label}</span>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="console-empty">
      <div class="space-y-2">
        <p class="text-sm font-semibold text-[var(--text-strong)]">{@title}</p>
        <p :if={@description} class="console-copy">{@description}</p>
      </div>
      <div :if={@action != []} class="pt-2">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  attr :data, :any, required: true
  attr :class, :string, default: nil

  def json_block(assigns) do
    ~H"""
    <pre class={["console-code-block", @class]}>{ConsoleHelpers.pretty_data(@data)}</pre>
    """
  end

  attr :tabs, :list, required: true

  def console_tabs(assigns) do
    ~H"""
    <div class="console-tabs">
      <.link
        :for={tab <- @tabs}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        class={["console-tab", tab[:active] && "console-tab-active"]}
      >
        {tab.label}
        <span :if={tab[:count]} class="console-tab-count">{tab.count}</span>
      </.link>
    </div>
    """
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(status), do: to_string(status)

  defp badge_label("needs_input"), do: "Needs Input"
  defp badge_label("mcp_oauth"), do: "OAuth"
  defp badge_label("static_bearer"), do: "Bearer"
  defp badge_label("built_in"), do: "Built-in"
  defp badge_label("always_ask"), do: "Confirm"
  defp badge_label(status), do: status |> String.replace("_", " ") |> Phoenix.Naming.humanize()

  defp badge_class(status, size) do
    size_class =
      case size do
        "small" -> "px-2 py-1 text-[10px]"
        _other -> "px-2.5 py-1 text-[11px]"
      end

    base = "console-badge #{size_class}"

    tone =
      cond do
        status in ["active", "completed", "idle"] ->
          "console-badge-success"

        status in ["needs_input", "confirm", "always_ask", "awaiting_confirmation"] ->
          "console-badge-warning"

        status in ["running", "mcp", "session", "unrestricted"] ->
          "console-badge-info"

        status in ["archived", "built_in", "static_bearer", "restricted"] ->
          "console-badge-neutral"

        status in ["errored", "error", "denied"] ->
          "console-badge-danger"

        status in ["custom", "resolved"] ->
          "console-badge-violet"

        true ->
          "console-badge-neutral"
      end

    base <> " " <> tone
  end
end
