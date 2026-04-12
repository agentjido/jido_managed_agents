defmodule JidoManagedAgentsWeb.PageControllerTest do
  use JidoManagedAgentsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Open-source control plane for managed AI agents"

    assert html =~
             "Author versioned agents, attach tools and MCP servers, isolate runtimes with environment templates"

    assert html =~ "Create Account"
  end
end
