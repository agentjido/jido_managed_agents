defmodule JidoManagedAgentsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use JidoManagedAgentsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint JidoManagedAgentsWeb.Endpoint

      use JidoManagedAgentsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import JidoManagedAgentsWeb.ConnCase
    end
  end

  setup tags do
    JidoManagedAgents.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def register_and_log_in_user(%{conn: conn} = context) do
    email = "live-user-#{System.unique_integer([:positive])}@example.com"
    password = "supersecret123"
    {:ok, hashed_password} = AshAuthentication.BcryptProvider.hash(password)

    JidoManagedAgents.Repo.query!(
      "INSERT INTO users (id, email, hashed_password, role, confirmed_at) VALUES ($1, $2, $3, $4, $5)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        email,
        hashed_password,
        "member",
        DateTime.utc_now()
      ]
    )

    user =
      JidoManagedAgents.Accounts.User
      |> Ash.Query.for_read(
        :sign_in_with_password,
        %{email: email, password: password},
        domain: JidoManagedAgents.Accounts,
        authorize?: false
      )
      |> Ash.read_one!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    context
    |> Map.put(:conn, conn)
    |> Map.put(:current_user, user)
  end
end
