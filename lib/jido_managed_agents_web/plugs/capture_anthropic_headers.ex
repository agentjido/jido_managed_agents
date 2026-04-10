defmodule JidoManagedAgentsWeb.Plugs.CaptureAnthropicHeaders do
  @moduledoc """
  Captures Anthropic-style compatibility headers for `/v1` requests.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    assign(conn, :anthropic_headers, %{
      version: List.first(get_req_header(conn, "anthropic-version")),
      betas: parse_betas(get_req_header(conn, "anthropic-beta"))
    })
  end

  defp parse_betas(values) do
    values
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
