defmodule JidoManagedAgents.Agents.AgentVersionCallableAgent do
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_version_callable_agents"
    repo JidoManagedAgents.Repo

    identity_index_names unique_agent_version_callable_agent: "avca_unique_callable_idx",
                         unique_agent_version_callable_agent_position: "avca_unique_pos_idx"
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
        :agent_version_id,
        :callable_agent_id,
        :callable_agent_version_id,
        :position,
        :metadata
      ]
    end

    update :update do
      primary? true
      accept [:callable_agent_version_id, :position, :metadata]
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :agent_version_id,
                    resource: JidoManagedAgents.Agents.AgentVersion,
                    domain: Agents}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :callable_agent_id,
                    resource: JidoManagedAgents.Agents.Agent,
                    domain: Agents}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :callable_agent_version_id,
                    resource: JidoManagedAgents.Agents.AgentVersion,
                    domain: Agents,
                    allow_nil?: true,
                    matches: [agent_id: :callable_agent_id]}
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

    belongs_to :agent_version, JidoManagedAgents.Agents.AgentVersion do
      allow_nil? false
      public? true
    end

    belongs_to :callable_agent, JidoManagedAgents.Agents.Agent do
      allow_nil? false
      public? true
    end

    belongs_to :callable_agent_version, JidoManagedAgents.Agents.AgentVersion do
      public? true
    end
  end

  identities do
    identity :unique_agent_version_callable_agent, [:agent_version_id, :callable_agent_id]
    identity :unique_agent_version_callable_agent_position, [:agent_version_id, :position]
  end
end
