defmodule JidoManagedAgents.Integrations.CredentialResourceShapeTest do
  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias Ash.Resource.Info, as: ResourceInfo
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.CredentialType
  alias JidoManagedAgents.Integrations.Vault

  test "credential resource keeps queryable routing fields separate from encrypted secret storage" do
    create_action = ResourceInfo.action(Credential, :create, :create)
    update_action = ResourceInfo.action(Credential, :update, :update)
    vault_relationship = ResourceInfo.relationship(Credential, :vault)
    policy_checks = inspect(Info.policies(nil, Credential), pretty: true)
    create_policy = Enum.find(Info.policies(nil, Credential), &action_policy?(&1, :create))
    read_policy = Enum.find(Info.policies(nil, Credential), &action_policy?(&1, :read))
    update_policy = Enum.find(Info.policies(nil, Credential), &action_policy?(&1, :update))

    assert Credential in Ash.Domain.Info.resources(Integrations)
    assert ResourceInfo.attribute(Credential, :type).type == CredentialType
    assert ResourceInfo.attribute(Credential, :mcp_server_url).type == Ash.Type.String
    assert ResourceInfo.attribute(Credential, :token_endpoint).type == Ash.Type.String
    assert ResourceInfo.attribute(Credential, :client_id).type == Ash.Type.String
    assert ResourceInfo.attribute(Credential, :metadata).default == %{}
    assert ResourceInfo.attribute(Credential, :vault_id).type == Ash.Type.UUID

    assert ResourceInfo.attribute(Credential, :access_token) == nil
    assert ResourceInfo.attribute(Credential, :refresh_token) == nil
    assert ResourceInfo.attribute(Credential, :client_secret) == nil

    assert %{public?: false, sensitive?: true} =
             ResourceInfo.attribute(Credential, :encrypted_access_token)

    assert %{public?: false, sensitive?: true} =
             ResourceInfo.attribute(Credential, :encrypted_refresh_token)

    assert %{public?: false, sensitive?: true} =
             ResourceInfo.attribute(Credential, :encrypted_client_secret)

    assert %{public?: true, sensitive?: true} =
             ResourceInfo.calculation(Credential, :access_token)

    assert %{public?: true, sensitive?: true} =
             ResourceInfo.calculation(Credential, :refresh_token)

    assert %{public?: true, sensitive?: true} =
             ResourceInfo.calculation(Credential, :client_secret)

    assert create_action.accept == [
             :vault_id,
             :type,
             :mcp_server_url,
             :token_endpoint,
             :client_id,
             :metadata
           ]

    assert update_action.accept == [:metadata]

    assert Enum.map(create_action.arguments, & &1.name) |> Enum.sort() == [
             :access_token,
             :client_secret,
             :refresh_token
           ]

    assert Enum.map(update_action.arguments, & &1.name) |> Enum.sort() == [
             :access_token,
             :client_secret,
             :refresh_token
           ]

    assert vault_relationship.type == :belongs_to
    assert vault_relationship.destination == Vault
    assert vault_relationship.allow_nil? == false

    assert Enum.any?(
             ResourceInfo.identities(Credential),
             &(&1.name == :unique_credential_route_per_vault)
           )

    assert AshCloak in ResourceInfo.extensions(Credential)

    assert Enum.map(create_policy.policies, & &1.check_module) == [
             JidoManagedAgents.Authorization.Checks.VaultOwnedByActor
           ]

    assert Enum.map(read_policy.policies, & &1.check_module) == [
             Ash.Policy.Check.RelatesToActorVia
           ]

    assert Enum.map(update_policy.policies, & &1.check_module) == [
             Ash.Policy.Check.RelatesToActorVia
           ]

    assert policy_checks =~ "JidoManagedAgents.Authorization.Checks.PlatformAdmin"
  end

  defp action_policy?(policy, action_type) do
    Enum.any?(policy.condition, fn
      {Ash.Policy.Check.ActionType, opts} -> action_type in Keyword.fetch!(opts, :type)
      _ -> false
    end)
  end
end
