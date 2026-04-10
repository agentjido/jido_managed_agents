defmodule JidoManagedAgents.Agents.Environment do
  alias JidoManagedAgents.Agents.EnvironmentDefinition
  alias JidoManagedAgents.Agents.EnvironmentLifecycle

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "environments"
    repo JidoManagedAgents.Repo
  end

  actions do
    defaults [:read]

    read :by_id do
      get_by :id
    end

    create :create do
      primary? true
      accept [:user_id, :name, :description, :config, :metadata]
      change before_action(&__MODULE__.normalize_config_change/2)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :description, :config, :metadata]

      change before_action(fn changeset, _context ->
               case EnvironmentLifecycle.archived?(Ash.Changeset.get_data(changeset, :id)) do
                 {:ok, true} ->
                   Ash.Changeset.add_error(changeset,
                     field: :id,
                     message: "Archived environments are read-only."
                   )

                 {:ok, false} ->
                   changeset

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)

      change before_action(&__MODULE__.normalize_config_change/2)
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
               case EnvironmentLifecycle.delete_blockers(Ash.Changeset.get_data(changeset, :id)) do
                 {:ok, blockers} ->
                   case EnvironmentLifecycle.delete_conflict_message(blockers) do
                     nil ->
                       changeset

                     message ->
                       Ash.Changeset.add_error(changeset, field: :id, message: message)
                   end

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)
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

    attribute :config, :map do
      allow_nil? false
      public? true
      default %{}
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

    has_many :sessions, JidoManagedAgents.Sessions.Session
  end

  calculations do
    calculate :archived, :boolean, expr(not is_nil(archived_at))
  end

  identities do
    identity :unique_environment_name_per_user, [:user_id, :name]
  end

  def normalize_config_change(changeset, _context) do
    if changeset.action_type == :create or Ash.Changeset.changing_attribute?(changeset, :config) do
      case EnvironmentDefinition.normalize_config(
             Ash.Changeset.get_attribute(changeset, :config),
             field: "config"
           ) do
        {:ok, normalized_config} ->
          Ash.Changeset.force_change_attribute(changeset, :config, normalized_config)

        {:error, {:invalid_request, message}} ->
          Ash.Changeset.add_error(changeset, field: :config, message: message)
      end
    else
      changeset
    end
  end
end
