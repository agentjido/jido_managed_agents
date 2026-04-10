defmodule JidoManagedAgents.Agents.AgentVersion do
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.AgentLifecycle
  alias JidoManagedAgents.Agents.ToolDeclaration
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_versions"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true

      accept [
        :user_id,
        :agent_id,
        :version,
        :name,
        :description,
        :model,
        :system,
        :tools,
        :mcp_servers,
        :metadata
      ]

      argument :agent_version_skills, {:array, :map}
      argument :agent_version_callable_agents, {:array, :map}

      change manage_relationship(:agent_version_skills,
               type: :direct_control,
               order_is_key: :position
             )

      change manage_relationship(:agent_version_callable_agents,
               type: :direct_control,
               order_is_key: :position
             )

      change before_action(fn changeset, _context ->
               case AgentLifecycle.archived?(Ash.Changeset.get_attribute(changeset, :agent_id)) do
                 {:ok, true} ->
                   Ash.Changeset.add_error(changeset,
                     field: :agent_id,
                     message: "Archived agents are read-only."
                   )

                 {:ok, false} ->
                   changeset

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      accept []

      change cascade_destroy(:agent_version_skills, after_action?: false)
      change cascade_destroy(:agent_version_callable_agents, after_action?: false)
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :agent_id, resource: JidoManagedAgents.Agents.Agent, domain: Agents}
    end
  end

  validations do
    validate string_length(:name, min: 1)
    validate compare(:version, greater_than_or_equal_to: 1)
  end

  attributes do
    uuid_primary_key :id

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :model, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :system, :string do
      public? true
      constraints trim?: false
    end

    attribute :tools, {:array, ToolDeclaration} do
      allow_nil? false
      default []
      public? true
    end

    attribute :mcp_servers, {:array, :map} do
      allow_nil? false
      default []
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

    has_many :agent_version_skills, JidoManagedAgents.Agents.AgentVersionSkill
    has_many :agent_version_callable_agents, JidoManagedAgents.Agents.AgentVersionCallableAgent
    has_many :sessions, JidoManagedAgents.Sessions.Session
    has_many :session_threads, JidoManagedAgents.Sessions.SessionThread

    many_to_many :skills, JidoManagedAgents.Agents.Skill do
      through JidoManagedAgents.Agents.AgentVersionSkill
      source_attribute_on_join_resource :agent_version_id
      destination_attribute_on_join_resource :skill_id
    end

    many_to_many :callable_agents, JidoManagedAgents.Agents.Agent do
      through JidoManagedAgents.Agents.AgentVersionCallableAgent
      source_attribute_on_join_resource :agent_version_id
      destination_attribute_on_join_resource :callable_agent_id
    end
  end

  identities do
    identity :unique_agent_version_number, [:agent_id, :version]
  end
end
