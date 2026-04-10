defmodule JidoManagedAgentsWeb.Plugs.PrepareV1ApiKey do
  @moduledoc """
  Normalizes `/v1` authentication so only `x-api-key` is used for API key auth.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    headers = Enum.reject(conn.req_headers, fn {name, _value} -> name == "authorization" end)

    case conn |> get_req_header("x-api-key") |> List.first() |> normalize_api_key() do
      nil -> %{conn | req_headers: headers}
      api_key -> %{conn | req_headers: [{"authorization", "Bearer " <> api_key} | headers]}
    end
  end

  defp normalize_api_key(nil), do: nil

  defp normalize_api_key(api_key) do
    case String.trim(api_key) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
