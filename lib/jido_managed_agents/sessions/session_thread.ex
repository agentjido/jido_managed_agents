defmodule JidoManagedAgents.Sessions.SessionThread do
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor
  alias JidoManagedAgents.Sessions

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Sessions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "session_threads"
    repo JidoManagedAgents.Repo

    identity_index_names unique_primary_thread_per_session: "session_threads_unique_primary_idx"
    identity_wheres_to_sql unique_primary_thread_per_session: "role = 'primary'"
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true

      accept [
        :user_id,
        :session_id,
        :agent_id,
        :agent_version_id,
        :parent_thread_id,
        :role,
        :status,
        :stop_reason,
        :metadata
      ]
    end

    update :update do
      primary? true
      accept [:status, :stop_reason, :metadata]
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
                    attribute: :agent_id,
                    resource: JidoManagedAgents.Agents.Agent,
                    domain: Sessions}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :agent_version_id,
                    resource: JidoManagedAgents.Agents.AgentVersion,
                    domain: Sessions,
                    matches: [agent_id: :agent_id]}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :parent_thread_id,
                    resource: JidoManagedAgents.Sessions.SessionThread,
                    domain: Sessions,
                    allow_nil?: true,
                    matches: [session_id: :session_id]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, JidoManagedAgents.Sessions.SessionThreadRole do
      allow_nil? false
      default :primary
      public? true
    end

    attribute :status, JidoManagedAgents.Sessions.SessionThreadStatus do
      allow_nil? false
      default :idle
      public? true
    end

    attribute :stop_reason, :map do
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

    belongs_to :session, JidoManagedAgents.Sessions.Session do
      allow_nil? false
      public? true
    end

    belongs_to :agent, JidoManagedAgents.Agents.Agent do
      allow_nil? false
      public? true
    end

    belongs_to :agent_version, JidoManagedAgents.Agents.AgentVersion do
      allow_nil? false
      public? true
    end

    belongs_to :parent_thread, __MODULE__ do
      public? true
    end

    has_many :child_threads, __MODULE__ do
      destination_attribute :parent_thread_id
    end

    has_many :events, JidoManagedAgents.Sessions.SessionEvent do
      sort sequence: :asc
    end
  end

  identities do
    identity :unique_primary_thread_per_session, [:session_id],
      where: expr(role == :primary),
      message: "session already has a primary thread"
  end
end
