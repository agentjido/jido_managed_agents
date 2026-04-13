defmodule JidoManagedAgentsWeb.FeatureHelpers do
  @moduledoc false

  use JidoManagedAgentsWeb, :verified_routes

  import PhoenixTest
  import PhoenixTest.Playwright, only: [evaluate: 3]

  alias JidoManagedAgents.Accounts
  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Repo

  @password_sign_in_email "#user-password-sign-in-with-password_email"
  @password_sign_in_password "#user-password-sign-in-with-password_password"
  @password_sign_in_submit "#user-password-sign-in-with-password button"

  def create_password_user!(attrs \\ %{}) do
    email =
      Map.get(attrs, :email) ||
        "browser-user-#{System.unique_integer([:positive])}@example.com"

    password = Map.get(attrs, :password, "supersecret123")
    role = Map.get(attrs, :role, "member")
    {:ok, hashed_password} = AshAuthentication.BcryptProvider.hash(password)

    Repo.query!(
      "INSERT INTO users (id, email, hashed_password, role, confirmed_at) VALUES ($1, $2, $3, $4, $5)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        email,
        hashed_password,
        role,
        DateTime.utc_now()
      ]
    )

    user =
      User
      |> Ash.Query.for_read(
        :sign_in_with_password,
        %{email: email, password: password},
        domain: Accounts,
        authorize?: false
      )
      |> Ash.read_one!()

    %{user: user, password: password}
  end

  def sign_in(conn, %{user: user, password: password}) do
    conn
    |> visit(~p"/sign-in")
    |> assert_has("body .phx-connected")
    |> submit_sign_in_form(user.email, password)
    |> assert_path(~p"/console")
  end

  def sign_in_through_home(conn, %{user: user, password: password}) do
    conn
    |> visit(~p"/")
    |> click_link("header a[href='/sign-in']", "Sign In")
    |> assert_path(~p"/sign-in")
    |> assert_has("body .phx-connected")
    |> submit_sign_in_form(user.email, password)
    |> assert_path(~p"/console")
  end

  def visit_live(session, path) do
    session
    |> visit(path)
    |> assert_has("body .phx-connected")
  end

  def set_form_value(session, selector, value) when is_binary(selector) do
    selector_json = Jason.encode!(selector)
    value_json = Jason.encode!(value)

    session
    |> evaluate(
      """
      (() => {
        const field = document.querySelector(#{selector_json});
        if (!field) return null;
        field.value = #{value_json};
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
        return field.value;
      })()
      """,
      fn selected ->
        if selected != value do
          raise ExUnit.AssertionError,
            message: "Expected #{selector} to be #{inspect(value)}, got #{inspect(selected)}"
        end
      end
    )
  end

  defp submit_sign_in_form(session, email, password) do
    session
    |> fill_in(@password_sign_in_email, "Email", with: email)
    |> fill_in(@password_sign_in_password, "Password", with: password)
    |> click_button(@password_sign_in_submit, "Sign in")
  end
end
