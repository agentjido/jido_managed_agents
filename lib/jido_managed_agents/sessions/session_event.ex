defmodule JidoManagedAgents.Sessions.SessionEvent do
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.SessionStream

  require JidoManagedAgents.Authorization

  use Ash.Resource,
    otp_app: :jido_managed_agents,
    domain: JidoManagedAgents.Sessions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "session_events"
    repo JidoManagedAgents.Repo

    identity_index_names unique_session_event_sequence: "session_events_unique_sequence_idx"
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
        :session_id,
        :session_thread_id,
        :sequence,
        :type,
        :content,
        :payload,
        :processed_at,
        :stop_reason,
        :metadata
      ]

      change &__MODULE__.broadcast_stream_event/2
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
                    attribute: :session_thread_id,
                    resource: JidoManagedAgents.Sessions.SessionThread,
                    domain: Sessions,
                    allow_nil?: true,
                    matches: [session_id: :session_id]}
    end
  end

  validations do
    validate compare(:sequence, greater_than_or_equal_to: 0)
  end

  attributes do
    uuid_primary_key :id

    attribute :sequence, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :type, JidoManagedAgents.Sessions.SessionEventType do
      allow_nil? false
      public? true
    end

    attribute :content, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :payload, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :processed_at, :utc_datetime_usec do
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

    belongs_to :session_thread, JidoManagedAgents.Sessions.SessionThread do
      public? true
    end
  end

  identities do
    identity :unique_session_event_sequence, [:session_id, :sequence]
  end

  def broadcast_stream_event(changeset, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, event} when is_struct(event, __MODULE__) ->
          SessionStream.broadcast_event(event)
          result

        _other ->
          result
      end
    end)
  end
end
