defmodule JidoManagedAgentsWeb.V1.Controller do
  @moduledoc """
  Shared controller helpers for the Anthropic-style `/v1` API surface.
  """

  alias JidoManagedAgents.AshActor
  alias JidoManagedAgentsWeb.V1.Response

  defmacro __using__(_opts) do
    quote do
      use JidoManagedAgentsWeb, :controller

      action_fallback(JidoManagedAgentsWeb.V1.FallbackController)

      import JidoManagedAgentsWeb.V1.Controller
    end
  end

  @spec ash_opts(Plug.Conn.t(), keyword()) :: keyword()
  def ash_opts(conn, opts \\ []) when is_list(opts) do
    AshActor.ash_opts(conn, opts)
  end

  @spec render_list(Plug.Conn.t(), list(), (term() -> map()), keyword()) :: Plug.Conn.t()
  def render_list(conn, data, serializer, opts \\ [])
      when is_list(data) and is_function(serializer, 1) and is_list(opts) do
    Phoenix.Controller.json(conn, Response.list(Enum.map(data, serializer), opts))
  end

  @spec render_object(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def render_object(conn, data) when is_map(data) do
    Phoenix.Controller.json(conn, data)
  end

  @spec render_error(Plug.Conn.t(), Plug.Conn.status(), String.t(), String.t()) :: Plug.Conn.t()
  def render_error(conn, status, type, message) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.json(Response.error(type, message))
  end
end
