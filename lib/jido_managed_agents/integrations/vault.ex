defmodule JidoManagedAgents.Integrations.Vault do
  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "vaults"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :name, :description, :display_metadata, :metadata]
    end

    update :update do
      primary? true
      accept [:name, :description, :display_metadata, :metadata]
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)
  end

  validations do
    validate string_length(:name, min: 1)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :display_metadata, :map do
      allow_nil? false
      default %{}
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
    belongs_to :user, JidoManagedAgents.Accounts.User do
      allow_nil? false
      public? true
    end

    has_many :credentials, JidoManagedAgents.Integrations.Credential
    has_many :session_vaults, JidoManagedAgents.Sessions.SessionVault

    many_to_many :sessions, JidoManagedAgents.Sessions.Session do
      through JidoManagedAgents.Sessions.SessionVault
      source_attribute_on_join_resource :vault_id
      destination_attribute_on_join_resource :session_id
    end
  end

  identities do
    identity :unique_vault_name_per_user, [:user_id, :name]
  end
end
