defmodule JidoManagedAgents.Sessions.Workspace do
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor
  alias JidoManagedAgents.Sessions

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Sessions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "workspaces"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :agent_id, :name, :backend, :config, :state, :last_used_at, :metadata]
    end

    update :update do
      primary? true
      accept [:name, :backend, :config, :state, :last_used_at, :metadata]
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :agent_id,
                    resource: JidoManagedAgents.Agents.Agent,
                    domain: Sessions}
    end
  end

  validations do
    validate string_length(:name, min: 1)
    validate string_length(:state, min: 1)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :backend, JidoManagedAgents.Sessions.WorkspaceBackend do
      allow_nil? false
      public? true
      default :memory_vfs
    end

    attribute :config, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :state, :string do
      allow_nil? false
      default "ready"
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
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

    belongs_to :agent, JidoManagedAgents.Agents.Agent do
      allow_nil? false
      public? true
    end

    has_many :sessions, JidoManagedAgents.Sessions.Session
  end

  identities do
    identity :unique_workspace_per_user_agent, [:user_id, :agent_id]
  end
end
