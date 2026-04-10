defmodule JidoManagedAgents.Agents.Agent do
  alias JidoManagedAgents.Agents.AgentLifecycle
  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agents"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :name, :description, :metadata]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :description, :metadata]

      change before_action(fn changeset, _context ->
               case AgentLifecycle.archived?(Ash.Changeset.get_data(changeset, :id)) do
                 {:ok, true} ->
                   Ash.Changeset.add_error(changeset,
                     field: :id,
                     message: "Archived agents are read-only."
                   )

                 {:ok, false} ->
                   changeset

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)
    end

    update :archive do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      accept []

      change before_action(fn changeset, _context ->
               case AgentLifecycle.delete_blockers(Ash.Changeset.get_data(changeset, :id)) do
                 {:ok, blockers} ->
                   case AgentLifecycle.delete_conflict_message(blockers) do
                     nil ->
                       changeset

                     message ->
                       Ash.Changeset.add_error(changeset, field: :id, message: message)
                   end

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)

      change cascade_destroy(:versions, after_action?: false)
      change cascade_destroy(:workspaces, after_action?: false)
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

    has_many :versions, JidoManagedAgents.Agents.AgentVersion

    has_one :latest_version, JidoManagedAgents.Agents.AgentVersion do
      domain JidoManagedAgents.Agents
      destination_attribute :agent_id
      sort version: :desc
      public? true
    end

    has_many :workspaces, JidoManagedAgents.Sessions.Workspace
    has_many :sessions, JidoManagedAgents.Sessions.Session
  end

  calculations do
    calculate :archived, :boolean, expr(not is_nil(archived_at))
  end

  aggregates do
    count :version_count, :versions
    max :latest_version_number, :versions, :version
  end

  identities do
    identity :unique_agent_name_per_user, [:user_id, :name]
  end
end
