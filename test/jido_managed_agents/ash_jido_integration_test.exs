defmodule JidoManagedAgents.AshJidoIntegrationTest do
  use JidoManagedAgents.DataCase, async: false

  test "generated AshJido actions run against the Accounts domain" do
    email = "ash-jido-#{System.unique_integer([:positive])}@example.com"

    JidoManagedAgents.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: email,
        password: "supersecret123",
        password_confirmation: "supersecret123"
      },
      domain: JidoManagedAgents.Accounts,
      authorize?: false
    )
    |> Ash.create!()

    assert {:ok, %{result: [user]}} =
             Jido.Exec.run(
               JidoManagedAgents.Accounts.User.Jido.GetByEmail,
               %{email: email},
               %{domain: JidoManagedAgents.Accounts, authorize?: false}
             )

    assert user |> Map.get(:email) |> to_string() == email

    assert {:ok, %{result: users}} =
             Jido.Exec.run(
               JidoManagedAgents.Accounts.User.Jido.Read,
               %{},
               %{domain: JidoManagedAgents.Accounts, authorize?: false}
             )

    assert Enum.any?(users, &(to_string(Map.get(&1, :email)) == email))
  end
end
