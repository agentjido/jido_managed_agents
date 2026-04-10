defmodule JidoManagedAgents.Sessions.SessionVault do
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor
  alias JidoManagedAgents.Sessions

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Sessions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "session_vaults"
    repo JidoManagedAgents.Repo

    identity_index_names unique_session_vault: "session_vaults_unique_vault_idx",
                         unique_session_vault_position: "session_vaults_unique_pos_idx"
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :session_id, :vault_id, :position, :metadata]
    end

    update :update do
      primary? true
      accept [:position, :metadata]
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :session_id,
                    resource: JidoManagedAgents.Sessions.Session,
                    domain: Sessions}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :vault_id,
                    resource: JidoManagedAgents.Integrations.Vault,
                    domain: Sessions}
    end
  end

  validations do
    validate compare(:position, greater_than_or_equal_to: 0)
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
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

    belongs_to :session, JidoManagedAgents.Sessions.Session do
      allow_nil? false
      public? true
    end

    belongs_to :vault, JidoManagedAgents.Integrations.Vault do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_session_vault, [:session_id, :vault_id]
    identity :unique_session_vault_position, [:session_id, :position]
  end
end
