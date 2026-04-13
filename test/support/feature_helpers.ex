defmodule JidoManagedAgentsWeb.FeatureHelpers do
  @moduledoc false

  use JidoManagedAgentsWeb, :verified_routes

  import PhoenixTest

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

  defp submit_sign_in_form(session, email, password) do
    session
    |> fill_in(@password_sign_in_email, "Email", with: email)
    |> fill_in(@password_sign_in_password, "Password", with: password)
    |> click_button(@password_sign_in_submit, "Sign in")
  end
end
