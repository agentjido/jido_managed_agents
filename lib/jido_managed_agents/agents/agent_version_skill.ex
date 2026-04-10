defmodule JidoManagedAgents.Agents.AgentVersionSkill do
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_version_skills"
    repo JidoManagedAgents.Repo

    identity_index_names unique_agent_version_skill: "avs_unique_skill_idx",
                         unique_agent_version_skill_position: "avs_unique_pos_idx"
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :agent_version_id, :skill_id, :skill_version_id, :position, :metadata]
    end

    update :update do
      primary? true
      accept [:skill_version_id, :position, :metadata]
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
                    attribute: :skill_id, resource: JidoManagedAgents.Agents.Skill, domain: Agents}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :skill_version_id,
                    resource: JidoManagedAgents.Agents.SkillVersion,
                    domain: Agents,
                    allow_nil?: true,
                    matches: [skill_id: :skill_id]}
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

    belongs_to :skill, JidoManagedAgents.Agents.Skill do
      allow_nil? false
      public? true
    end

    belongs_to :skill_version, JidoManagedAgents.Agents.SkillVersion do
      public? true
    end
  end

  identities do
    identity :unique_agent_version_skill, [:agent_version_id, :skill_id]
    identity :unique_agent_version_skill_position, [:agent_version_id, :position]
  end
end
