defmodule JidoManagedAgentsWeb.V1.FallbackController do
  @moduledoc """
  Translates `/v1` action results into Anthropic-style error envelopes.
  """

  use JidoManagedAgentsWeb, :controller

  import JidoManagedAgentsWeb.V1.Controller, only: [render_error: 4]

  def call(conn, {:error, :not_found}) do
    render_error(conn, :not_found, "not_found_error", "Resource not found.")
  end

  def call(conn, {:error, %Ash.Error.Forbidden{}}) do
    render_error(conn, :forbidden, "permission_error", "Request is not permitted.")
  end

  def call(conn, {:error, %Ash.Error.Invalid{} = error}) do
    render_error(conn, :bad_request, "invalid_request_error", Exception.message(error))
  end

  def call(conn, {:error, {:invalid_request, message}}) when is_binary(message) do
    render_error(conn, :bad_request, "invalid_request_error", message)
  end

  def call(conn, {:error, {:conflict, message}}) when is_binary(message) do
    render_error(conn, :conflict, "conflict_error", message)
  end

  def call(conn, {:error, error}) do
    render_error(conn, :internal_server_error, "api_error", Exception.message(error))
  end
end
