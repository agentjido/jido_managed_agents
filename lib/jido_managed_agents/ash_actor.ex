defmodule JidoManagedAgents.AshActor do
  @moduledoc """
  Normalizes Ash actor propagation across browser, API, LiveView, and runtime
  entry points.
  """

  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3]

  @type source ::
          Plug.Conn.t()
          | Socket.t()
          | map()
          | Ash.Resource.record()
          | nil

  @spec actor(source) :: term()
  def actor(%Plug.Conn{} = conn) do
    Ash.PlugHelpers.get_actor(conn) || conn.assigns[:current_user]
  end

  def actor(%Socket{} = socket) do
    socket.assigns[:current_actor] || socket.assigns[:current_user]
  end

  def actor(%{} = assigns) do
    Map.get(assigns, :current_actor) || Map.get(assigns, :current_user)
  end

  def actor(nil), do: nil
  def actor(actor), do: actor

  @spec ash_opts(source, keyword) :: keyword
  def ash_opts(source, opts \\ []) when is_list(opts) do
    case actor(source) do
      nil -> opts
      actor -> Keyword.put_new(opts, :actor, actor)
    end
  end

  @spec jido_opts(source, map) :: map
  def jido_opts(source, opts \\ %{}) when is_map(opts) do
    case actor(source) do
      nil -> opts
      actor -> Map.put_new(opts, :actor, actor)
    end
  end

  @spec assign_socket_actor(Socket.t()) :: Socket.t()
  def assign_socket_actor(%Socket{} = socket) do
    assign(socket, :current_actor, actor(socket))
  end
end
