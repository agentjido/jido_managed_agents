defmodule JidoManagedAgentsWeb.AuthFeatureTest do
  use PhoenixTest.Playwright.Case, async: false

  use JidoManagedAgentsWeb, :verified_routes

  import JidoManagedAgentsWeb.FeatureHelpers

  @moduletag :playwright
  @moduletag ecto_sandbox_stop_owner_delay: 100

  test "authenticated users are redirected away from auth screens", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> visit(~p"/sign-in")
    |> assert_path(~p"/console")
    |> visit(~p"/register")
    |> assert_path(~p"/console")
  end

  test "sign out returns home and clears console access", %{conn: conn} do
    credentials = create_password_user!()

    conn
    |> sign_in(credentials)
    |> evaluate("""
    (() => {
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
      const form = document.createElement("form");

      form.method = "post";
      form.action = "/sign-out";
      form.innerHTML = `
        <input type="hidden" name="_method" value="delete">
        <input type="hidden" name="_csrf_token" value="${csrf}">
      `;

      document.body.appendChild(form);
      form.submit();
      return true;
    })()
    """)
    |> assert_path(~p"/")
    |> assert_has("body", text: "You are now signed out")
    |> visit(~p"/console")
    |> assert_path(~p"/sign-in")
    |> assert_has("body .phx-connected")
  end
end
