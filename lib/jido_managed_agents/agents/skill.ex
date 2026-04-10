defmodule JidoManagedAgents.Agents.Skill do
  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "skills"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :type, :name, :description, :metadata]
    end

    update :update do
      primary? true
      accept [:type, :name, :description, :metadata]
    end

    update :archive do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, &DateTime.utc_now/0)
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

    attribute :type, JidoManagedAgents.Agents.SkillKind do
      allow_nil? false
      default :custom
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :archived_at, :utc_datetime_usec do
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

    has_many :versions, JidoManagedAgents.Agents.SkillVersion

    has_one :latest_version, JidoManagedAgents.Agents.SkillVersion do
      domain JidoManagedAgents.Agents
      destination_attribute :skill_id
      sort version: :desc
      public? true
    end
  end

  calculations do
    calculate :archived, :boolean, expr(not is_nil(archived_at))
  end

  aggregates do
    count :version_count, :versions
    max :latest_version_number, :versions, :version
  end

  identities do
    identity :unique_skill_name_per_user, [:user_id, :name]
  end
end
