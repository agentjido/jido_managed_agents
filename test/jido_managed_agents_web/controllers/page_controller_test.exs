defmodule JidoManagedAgentsWeb.PageControllerTest do
  use JidoManagedAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Build, run, and inspect managed agents without losing the thread."
    assert html =~ "Open source control plane for agent execution"
    assert html =~ "Create Account"
  end
end
