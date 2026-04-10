defmodule JidoManagedAgentsWeb.V1.ApiKeyAuthError do
  @moduledoc """
  Emits Anthropic-style authentication errors for `/v1` API key requests.
  """

  import Plug.Conn

  alias JidoManagedAgentsWeb.V1.Response

  @spec on_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def on_error(conn, reason) do
    message =
      case reason do
        :missing_api_key -> "x-api-key header is required."
        _ -> "Invalid x-api-key."
      end

    body =
      Phoenix.json_library().encode_to_iodata!(Response.error("authentication_error", message))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
