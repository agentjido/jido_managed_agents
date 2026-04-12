defmodule JidoManagedAgentsWeb.AuthLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  test "authenticated users are redirected from sign-in and register to the console", %{
    conn: conn
  } do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert {:error, {:redirect, %{to: "/console"}}} = live(conn, ~p"/sign-in")
    assert {:error, {:redirect, %{to: "/console"}}} = live(conn, ~p"/register")
  end
end
