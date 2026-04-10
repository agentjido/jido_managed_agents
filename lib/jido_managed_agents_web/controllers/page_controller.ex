defmodule JidoManagedAgentsWeb.PageController do
  use JidoManagedAgentsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
