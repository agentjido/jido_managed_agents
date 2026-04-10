defmodule JidoManagedAgents.Integrations.CredentialPersistenceTest do
  use JidoManagedAgents.DataCase, async: false

  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Platform.Architecture

  setup_all do
    if is_nil(Process.whereis(JidoManagedAgents.Vault)) do
      start_supervised!(JidoManagedAgents.Vault)
    end

    :ok
  end

  test "credential owner isolation only permits access through the owning vault" do
    owner = create_user!()
    other = create_user!()
    vault = create_vault!(owner)
    credential = create_credential!(owner, vault)

    owner_query =
      Credential
      |> Ash.Query.for_read(:by_id, %{id: credential.id}, actor: owner, domain: Integrations)
      |> Ash.read_one!()

    other_query =
      Credential
      |> Ash.Query.for_read(:by_id, %{id: credential.id}, actor: other, domain: Integrations)
      |> Ash.read_one!()

    owner_create =
      Credential
      |> Ash.Changeset.for_create(
        :create,
        %{
          vault_id: vault.id,
          type: :static_bearer,
          mcp_server_url: "https://mcp-owner-#{System.unique_integer([:positive])}.example.com",
          access_token: "owner-secret-#{System.unique_integer([:positive])}"
        },
        actor: owner,
        domain: Integrations
      )

    other_create =
      Credential
      |> Ash.Changeset.for_create(
        :create,
        %{
          vault_id: vault.id,
          type: :static_bearer,
          mcp_server_url: "https://mcp-other-#{System.unique_integer([:positive])}.example.com",
          access_token: "other-secret-#{System.unique_integer([:positive])}"
        },
        actor: other,
        domain: Integrations
      )

    assert owner_query.id == credential.id
    assert other_query == nil
    assert Ash.can?(owner_create, owner, domain: Integrations)
    refute Ash.can?(other_create, other, domain: Integrations)
  end

  test "secret attributes persist as ciphertext and stay outside default serialized payloads" do
    owner = create_user!()
    vault = create_vault!(owner)
    access_token = "access-#{System.unique_integer([:positive])}"
    refresh_token = "refresh-#{System.unique_integer([:positive])}"
    client_secret = "client-secret-#{System.unique_integer([:positive])}"
    mcp_server_url = "https://mcp-#{System.unique_integer([:positive])}.example.com"
    token_endpoint = "https://auth-#{System.unique_integer([:positive])}.example.com/oauth/token"
    client_id = "client-#{System.unique_integer([:positive])}"

    credential =
      create_credential!(owner, vault,
        type: :mcp_oauth,
        mcp_server_url: mcp_server_url,
        token_endpoint: token_endpoint,
        client_id: client_id,
        access_token: access_token,
        refresh_token: refresh_token,
        client_secret: client_secret
      )

    assert is_binary(credential.encrypted_access_token)
    assert is_binary(credential.encrypted_refresh_token)
    assert is_binary(credential.encrypted_client_secret)
    refute credential.encrypted_access_token == access_token
    refute credential.encrypted_refresh_token == refresh_token
    refute credential.encrypted_client_secret == client_secret
    assert %Ash.NotLoaded{type: :calculation, field: :access_token} = credential.access_token
    assert %Ash.NotLoaded{type: :calculation, field: :refresh_token} = credential.refresh_token
    assert %Ash.NotLoaded{type: :calculation, field: :client_secret} = credential.client_secret

    assert %{
             rows: [
               [
                 "mcp_oauth",
                 ^mcp_server_url,
                 ^token_endpoint,
                 ^client_id,
                 encrypted_access_token,
                 encrypted_refresh_token,
                 encrypted_client_secret
               ]
             ]
           } =
             Repo.query!(
               """
               SELECT type, mcp_server_url, token_endpoint, client_id,
                      encrypted_access_token, encrypted_refresh_token, encrypted_client_secret
               FROM credentials
               WHERE id = $1
               """,
               [dump_uuid!(credential.id)]
             )

    refute encrypted_access_token == access_token
    refute encrypted_refresh_token == refresh_token
    refute encrypted_client_secret == client_secret

    serialized_payload = default_serialized_payload(credential)
    json_payload = Jason.encode!(serialized_payload)

    refute Map.has_key?(serialized_payload, :access_token)
    refute Map.has_key?(serialized_payload, :refresh_token)
    refute Map.has_key?(serialized_payload, :client_secret)
    refute Map.has_key?(serialized_payload, :encrypted_access_token)
    refute Map.has_key?(serialized_payload, :encrypted_refresh_token)
    refute Map.has_key?(serialized_payload, :encrypted_client_secret)
    assert serialized_payload.type == :mcp_oauth
    assert serialized_payload.mcp_server_url == mcp_server_url
    assert serialized_payload.token_endpoint == token_endpoint
    assert serialized_payload.client_id == client_id
    refute json_payload =~ access_token
    refute json_payload =~ refresh_token
    refute json_payload =~ client_secret

    loaded_credential =
      Ash.load!(credential, [:access_token, :refresh_token, :client_secret],
        actor: owner,
        domain: Integrations
      )

    assert loaded_credential.access_token == access_token
    assert loaded_credential.refresh_token == refresh_token
    assert loaded_credential.client_secret == client_secret

    assert Architecture.integrations_secret_model().credential_queryable_fields == [
             :vault_id,
             :type,
             :mcp_server_url,
             :token_endpoint,
             :client_id,
             :metadata
           ]

    assert Architecture.integrations_secret_model().credential_encrypted_fields == [
             :access_token,
             :refresh_token,
             :client_secret
           ]
  end

  defp create_user! do
    user = %User{
      id: Ecto.UUID.generate(),
      email: "credential-user-#{System.unique_integer([:positive])}@example.com",
      role: :member
    }

    Repo.query!(
      "INSERT INTO users (id, email, role) VALUES ($1, $2, $3)",
      [dump_uuid!(user.id), user.email, to_string(user.role)]
    )

    user
  end

  defp create_vault!(user) do
    Vault
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        name: "vault-#{System.unique_integer([:positive])}",
        description: "Credentials",
        display_metadata: %{label: "Primary"},
        metadata: %{external_id: "vault-#{System.unique_integer([:positive])}"}
      },
      actor: user,
      domain: Integrations
    )
    |> Ash.create!()
  end

  defp create_credential!(user, vault, attrs \\ %{}) do
    defaults = %{
      vault_id: vault.id,
      type: :static_bearer,
      mcp_server_url: "https://mcp-#{System.unique_integer([:positive])}.example.com",
      access_token: "token-#{System.unique_integer([:positive])}",
      metadata: %{source: "test"}
    }

    Credential
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)),
      actor: user,
      domain: Integrations
    )
    |> Ash.create!()
  end

  defp default_serialized_payload(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> then(&Map.take(record, &1))
  end

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
