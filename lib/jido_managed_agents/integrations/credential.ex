defmodule JidoManagedAgents.Integrations.Credential do
  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "credentials"
    repo JidoManagedAgents.Repo
  end

  cloak do
    vault(JidoManagedAgents.Vault)
    attributes([:access_token, :refresh_token, :client_secret])
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true

      accept [
        :vault_id,
        :type,
        :mcp_server_url,
        :token_endpoint,
        :client_id,
        :access_token,
        :refresh_token,
        :client_secret,
        :metadata
      ]
    end

    update :update do
      primary? true
      accept [:access_token, :refresh_token, :client_secret, :metadata]
    end
  end

  policies do
    JidoManagedAgents.Authorization.platform_admin_override()

    policy action_type(:create) do
      authorize_if JidoManagedAgents.Authorization.Checks.VaultOwnedByActor
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:vault, :user])
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via([:vault, :user])
    end
  end

  validations do
    validate string_length(:mcp_server_url, min: 1)
  end

  attributes do
    uuid_primary_key :id

    attribute :type, JidoManagedAgents.Integrations.CredentialType do
      allow_nil? false
      public? true
    end

    attribute :mcp_server_url, :string do
      allow_nil? false
      public? true
    end

    attribute :token_endpoint, :string do
      public? true
    end

    attribute :client_id, :string do
      public? true
    end

    attribute :access_token, :string do
      sensitive? true
      public? true
    end

    attribute :refresh_token, :string do
      sensitive? true
      public? true
    end

    attribute :client_secret, :string do
      sensitive? true
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vault, JidoManagedAgents.Integrations.Vault do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_credential_route_per_vault, [:vault_id, :type, :mcp_server_url]
  end
end
