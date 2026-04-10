defmodule JidoManagedAgents.Agents.SkillVersion do
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "skill_versions"
    repo JidoManagedAgents.Repo
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
        :skill_id,
        :version,
        :description,
        :body,
        :source_path,
        :allowed_tools,
        :manifest,
        :metadata
      ]
    end
  end

  policies do
    JidoManagedAgents.Authorization.owner_or_admin_policies(:user)

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :skill_id, resource: JidoManagedAgents.Agents.Skill, domain: Agents}
    end
  end

  validations do
    validate compare(:version, greater_than_or_equal_to: 1)
    validate string_length(:description, min: 1)
    validate present([:body, :source_path], at_least: 1)
  end

  attributes do
    uuid_primary_key :id

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :description, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string do
      public? true
    end

    attribute :source_path, :string do
      public? true
    end

    attribute :allowed_tools, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :manifest, :map do
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

    belongs_to :skill, JidoManagedAgents.Agents.Skill do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_skill_version_number, [:skill_id, :version]
  end
end
