defmodule JidoManagedAgents.Sessions.Session do
  alias JidoManagedAgents.Agents.AgentLifecycle
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.SessionEventLog
  alias JidoManagedAgents.Sessions.SessionSkillLimit
  alias JidoManagedAgents.Sessions.SessionStream
  alias JidoManagedAgents.Sessions.SessionThreads
  alias JidoManagedAgents.Sessions.Workspace

  require Ash.Query
  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Sessions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sessions"
    repo JidoManagedAgents.Repo
    base_filter_sql "deleted_at IS NULL"

    identity_index_names unique_active_session_per_workspace: "sessions_active_workspace_idx"
    identity_wheres_to_sql unique_active_session_per_workspace: "status IN ('idle', 'running')"
  end

  resource do
    base_filter expr(is_nil(deleted_at))
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
        :agent_version_id,
        :environment_id,
        :workspace_id,
        :title,
        :status,
        :stop_reason,
        :last_processed_event_index,
        :metadata
      ]

      argument :session_vaults, {:array, :map}

      change &__MODULE__.resolve_workspace_change/2

      change manage_relationship(:session_vaults,
               type: :direct_control,
               order_is_key: :position
             )

      change before_action(fn changeset, context ->
               case SessionSkillLimit.validate(
                      Ash.Changeset.get_attribute(changeset, :agent_version_id),
                      context.actor
                    ) do
                 :ok ->
                   changeset

                 {:error, {:invalid_request, message}} ->
                   Ash.Changeset.add_error(changeset, field: :agent_version_id, message: message)

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)

      change &__MODULE__.ensure_primary_thread_change/2
      change &__MODULE__.track_status_transition/2
      change &__MODULE__.broadcast_stream_closure/2

      change before_action(fn changeset, _context ->
               case AgentLifecycle.archived?(Ash.Changeset.get_attribute(changeset, :agent_id)) do
                 {:ok, true} ->
                   Ash.Changeset.add_error(changeset,
                     field: :agent_id,
                     message: "Archived agents cannot be used for new sessions."
                   )

                 {:ok, false} ->
                   changeset

                 {:error, error} ->
                   Ash.Changeset.add_error(changeset, error)
               end
             end)
    end

    update :update do
      primary? true
      accept [:title, :status, :stop_reason, :last_processed_event_index, :metadata]
      require_atomic? false
      change &__MODULE__.track_status_transition/2
      change &__MODULE__.broadcast_stream_closure/2
    end

    update :archive do
      accept []
      require_atomic? false
      change set_attribute(:status, :archived)
      change set_attribute(:archived_at, &DateTime.utc_now/0)
      change &__MODULE__.sync_primary_thread_change/2
      change &__MODULE__.broadcast_stream_closure/2
    end

    destroy :soft_delete do
      accept []
      require_atomic? false
      soft? true
      change set_attribute(:status, :deleted)
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
      change &__MODULE__.sync_primary_thread_change/2
      change &__MODULE__.broadcast_stream_closure/2
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

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :agent_version_id,
                    resource: JidoManagedAgents.Agents.AgentVersion,
                    domain: Sessions,
                    matches: [agent_id: :agent_id]}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :environment_id,
                    resource: JidoManagedAgents.Agents.Environment,
                    domain: Sessions}
    end

    policy action_type(:create) do
      authorize_if {ReferencedResourceOwnedByActor,
                    attribute: :workspace_id,
                    resource: JidoManagedAgents.Sessions.Workspace,
                    domain: Sessions,
                    matches: [agent_id: :agent_id]}
    end
  end

  validations do
    validate string_length(:title, min: 1), where: present(:title)
    validate compare(:last_processed_event_index, greater_than_or_equal_to: -1)
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      public? true
    end

    attribute :status, JidoManagedAgents.Sessions.SessionStatus do
      allow_nil? false
      default :idle
      public? true
    end

    attribute :stop_reason, :map do
      public? true
    end

    attribute :last_processed_event_index, :integer do
      allow_nil? false
      default -1
      public? true
      constraints min: -1
    end

    attribute :archived_at, :utc_datetime_usec do
      public? true
    end

    attribute :deleted_at, :utc_datetime_usec do
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

    belongs_to :agent_version, JidoManagedAgents.Agents.AgentVersion do
      allow_nil? false
      public? true
    end

    belongs_to :environment, JidoManagedAgents.Agents.Environment do
      allow_nil? false
      public? true
    end

    belongs_to :workspace, JidoManagedAgents.Sessions.Workspace do
      allow_nil? false
      public? true
    end

    has_many :session_vaults, JidoManagedAgents.Sessions.SessionVault do
      sort position: :asc
    end

    many_to_many :vaults, JidoManagedAgents.Integrations.Vault do
      through JidoManagedAgents.Sessions.SessionVault
      source_attribute_on_join_resource :session_id
      destination_attribute_on_join_resource :vault_id
    end

    has_many :threads, JidoManagedAgents.Sessions.SessionThread

    has_many :events, JidoManagedAgents.Sessions.SessionEvent do
      sort sequence: :asc
    end
  end

  calculations do
    calculate :active, :boolean, expr(status in [:idle, :running])
    calculate :archived, :boolean, expr(not is_nil(archived_at))
    calculate :deleted, :boolean, expr(not is_nil(deleted_at))
  end

  identities do
    identity :unique_active_session_per_workspace, [:workspace_id],
      where: expr(status in [:idle, :running]),
      message: "workspace already has an active session"
  end

  def resolve_workspace_change(changeset, _context) do
    with {:ok, user_id} <- fetch_required_attribute(changeset, :user_id),
         {:ok, agent_id} <- fetch_required_attribute(changeset, :agent_id),
         {:ok, workspace_id} <- fetch_optional_attribute(changeset, :workspace_id),
         {:ok, %Workspace{} = workspace} <- resolve_workspace(user_id, agent_id, workspace_id) do
      Ash.Changeset.force_change_attribute(changeset, :workspace_id, workspace.id)
    else
      {:error, {field, message}} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  def track_status_transition(changeset, _context) do
    previous_status = previous_status(changeset)
    next_status = Ash.Changeset.get_attribute(changeset, :status)

    if session_status_event?(previous_status, next_status) do
      Ash.Changeset.after_action(changeset, fn changeset, session ->
        actor = changeset.context[:private][:actor]

        with {:ok, _thread} <- SessionThreads.sync_primary_thread(session, actor),
             {:ok, _event} <-
               SessionEventLog.record_status_transition(session, next_status, actor) do
          {:ok, session}
        else
          {:error, error} -> {:error, error}
        end
      end)
    else
      changeset
    end
  end

  def ensure_primary_thread_change(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, session ->
      actor = changeset.context[:private][:actor]

      case SessionThreads.ensure_primary_thread(session, actor) do
        {:ok, _thread} -> {:ok, session}
        {:error, error} -> {:error, error}
      end
    end)
  end

  def sync_primary_thread_change(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, session ->
      actor = changeset.context[:private][:actor]

      case SessionThreads.sync_primary_thread(session, actor) do
        {:ok, _thread} -> {:ok, session}
        {:error, error} -> {:error, error}
      end
    end)
  end

  def broadcast_stream_closure(changeset, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, session} when is_struct(session, __MODULE__) ->
          if session.status in [:archived, :deleted] do
            SessionStream.broadcast_closed(session)
          end

          result

        _other ->
          result
      end
    end)
  end

  defp fetch_required_attribute(changeset, attribute) do
    case Ash.Changeset.fetch_argument_or_attribute(changeset, attribute) do
      {:ok, nil} -> {:error, {attribute, "is required"}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {attribute, "is required"}}
    end
  end

  defp fetch_optional_attribute(changeset, attribute) do
    case Ash.Changeset.fetch_argument_or_attribute(changeset, attribute) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, nil}
    end
  end

  defp previous_status(%Ash.Changeset{action_type: :create}), do: nil

  defp previous_status(%Ash.Changeset{} = changeset) do
    case Ash.Changeset.fetch_data(changeset, :status) do
      {:ok, status} -> status
      :error -> nil
    end
  end

  defp session_status_event?(previous_status, next_status)
       when next_status in [:idle, :running] and previous_status != next_status,
       do: true

  defp session_status_event?(_previous_status, _next_status), do: false

  defp resolve_workspace(user_id, agent_id, nil) do
    case load_default_workspace(user_id, agent_id) do
      {:ok, %Workspace{} = workspace} ->
        {:ok, workspace}

      {:ok, nil} ->
        {:error, {:workspace_id, "workspace must already exist for this user and agent"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_workspace(user_id, agent_id, workspace_id) do
    with {:ok, %Workspace{} = workspace} <- resolve_workspace(user_id, agent_id, nil),
         true <- workspace.id == workspace_id do
      {:ok, workspace}
    else
      false ->
        {:error,
         {:workspace_id, "workspace must match the resolved workspace for this user and agent"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_default_workspace(user_id, agent_id) do
    Workspace
    |> Ash.Query.for_read(:read, %{}, authorize?: false, domain: Sessions)
    |> Ash.Query.filter(user_id == ^user_id and agent_id == ^agent_id)
    |> Ash.read_one(authorize?: false, domain: Sessions)
  end
end
