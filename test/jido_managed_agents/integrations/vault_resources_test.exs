defmodule JidoManagedAgents.Integrations.VaultResourcesTest do
  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias Ash.Resource.Info, as: ResourceInfo
  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Platform.Architecture

  test "vault resource is explicit, owner-scoped, and stores only non-secret metadata fields" do
    create_action = ResourceInfo.action(Vault, :create, :create)
    update_action = ResourceInfo.action(Vault, :update, :update)
    user_relationship = ResourceInfo.relationship(Vault, :user)
    policy_checks = inspect(Info.policies(nil, Vault), pretty: true)

    assert Vault in Ash.Domain.Info.resources(Integrations)
    assert ResourceInfo.attribute(Vault, :name).allow_nil? == false
    assert ResourceInfo.attribute(Vault, :description).type == Ash.Type.String
    assert ResourceInfo.attribute(Vault, :display_metadata).default == %{}
    assert ResourceInfo.attribute(Vault, :metadata).default == %{}
    assert create_action.accept == [:user_id, :name, :description, :display_metadata, :metadata]
    assert update_action.accept == [:name, :description, :display_metadata, :metadata]
    assert user_relationship.type == :belongs_to
    assert user_relationship.destination == User
    assert user_relationship.allow_nil? == false
    assert ResourceInfo.relationship(Vault, :credentials).destination == Credential
    assert Enum.any?(ResourceInfo.identities(Vault), &(&1.name == :unique_vault_name_per_user))
    assert policy_checks =~ "JidoManagedAgents.Authorization.Checks.PlatformAdmin"
    assert policy_checks =~ "Ash.Policy.Check.RelatingToActor"
    assert policy_checks =~ "Ash.Policy.Check.RelatesToActorVia"
    refute AshCloak in ResourceInfo.extensions(Vault)
  end

  test "vault owner isolation is expressed through Ash-native create, read, and update policies" do
    owner = create_user!()
    other = create_user!()

    owner_create =
      Vault
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: owner.id,
          name: "vault-#{System.unique_integer([:positive])}",
          description: "Owner vault",
          display_metadata: %{display_name: "Alice"},
          metadata: %{external_user_id: "usr_#{System.unique_integer([:positive])}"}
        },
        actor: owner,
        domain: Integrations
      )

    other_create =
      Vault
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: owner.id,
          name: "vault-#{System.unique_integer([:positive])}"
        },
        actor: other,
        domain: Integrations
      )

    create_policy = Enum.find(Info.policies(nil, Vault), &action_policy?(&1, :create))
    read_policy = Enum.find(Info.policies(nil, Vault), &action_policy?(&1, :read))
    update_policy = Enum.find(Info.policies(nil, Vault), &action_policy?(&1, :update))

    assert Ash.can?(owner_create, owner, domain: Integrations)
    refute Ash.can?(other_create, other, domain: Integrations)

    assert Enum.map(create_policy.policies, & &1.check_module) == [
             Ash.Policy.Check.RelatingToActor
           ]

    assert Enum.map(read_policy.policies, & &1.check_module) == [
             Ash.Policy.Check.RelatesToActorVia
           ]

    assert Enum.map(update_policy.policies, & &1.check_module) == [
             Ash.Policy.Check.RelatesToActorVia
           ]
  end

  test "user relationships and secret-model docs keep vault references normalized for later session joins" do
    user_relationship = ResourceInfo.relationship(User, :vaults)
    model = Architecture.integrations_secret_model()

    assert user_relationship.type == :has_many
    assert user_relationship.destination == Vault
    assert ResourceInfo.attribute(Vault, :id).type == Ash.Type.UUID
    assert ResourceInfo.attribute(Vault, :created_at).type == Ash.Type.UtcDatetimeUsec
    assert ResourceInfo.attribute(Vault, :updated_at).type == Ash.Type.UtcDatetimeUsec
    assert model.vault_resource == Vault

    assert model.normalized_runtime_reference == %{
             join_resource: JidoManagedAgents.Sessions.SessionVault,
             parent_foreign_key: :vault_id
           }

    assert model.session_resolution_flow == [
             "Sessions attach vault access through ordered SessionVault join rows instead of embedding opaque secret blobs on Session.",
             "Runtime credential lookup walks SessionVault rows in ascending position, then matches credentials within each Vault by queryable routing fields such as MCP server URL.",
             "Only the matched credential's encrypted secret attributes are decrypted at runtime for tool or MCP execution."
           ]
  end

  defp create_user! do
    %User{
      id: Ecto.UUID.generate(),
      email: "user-#{System.unique_integer([:positive])}@example.com",
      role: :member
    }
  end

  defp action_policy?(policy, action_type) do
    Enum.any?(policy.condition, fn
      {Ash.Policy.Check.ActionType, opts} -> action_type in Keyword.fetch!(opts, :type)
      _ -> false
    end)
  end
end
