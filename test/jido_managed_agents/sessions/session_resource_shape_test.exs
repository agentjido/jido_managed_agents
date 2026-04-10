defmodule JidoManagedAgents.Sessions.SessionResourceShapeTest do
  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias Ash.Resource.Change.ManageRelationship
  alias Ash.Resource.Info, as: ResourceInfo
  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Agents.{Agent, AgentVersion, Environment}
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventType,
    SessionStatus,
    SessionThread,
    SessionThreadRole,
    SessionThreadStatus,
    SessionVault,
    Workspace,
    WorkspaceBackend
  }

  @owner_scoped_resources [
    Workspace,
    Session,
    SessionVault,
    SessionThread,
    SessionEvent
  ]

  test "sessions domain registers explicit runtime resources with owner/admin policies" do
    assert Ash.Domain.Info.resources(Sessions) == @owner_scoped_resources

    for resource <- @owner_scoped_resources do
      user_relationship = ResourceInfo.relationship(resource, :user)
      create_action = ResourceInfo.action(resource, :create, :create)
      policy_checks = inspect(Info.policies(nil, resource), pretty: true)

      assert user_relationship.type == :belongs_to
      assert user_relationship.destination == User
      assert user_relationship.allow_nil? == false
      assert :user_id in create_action.accept
      assert policy_checks =~ "JidoManagedAgents.Authorization.Checks.PlatformAdmin"
      assert policy_checks =~ "Ash.Policy.Check.RelatingToActor"
      assert policy_checks =~ "Ash.Policy.Check.RelatesToActorVia"
    end
  end

  test "workspace and session relationships stay explicit and vault ordering remains normalized" do
    create_action = ResourceInfo.action(Session, :create, :create)
    session_vault_relationship = ResourceInfo.relationship(Session, :session_vaults)
    vaults_relationship = ResourceInfo.relationship(Session, :vaults)

    workspace_identity =
      Enum.find(
        ResourceInfo.identities(Workspace),
        &(&1.name == :unique_workspace_per_user_agent)
      )

    assert Workspace in Ash.Domain.Info.resources(Sessions)
    assert ResourceInfo.attribute(Workspace, :backend).type == WorkspaceBackend
    assert ResourceInfo.attribute(Workspace, :workspace_id) == nil
    assert ResourceInfo.attribute(Workspace, :state).type == Ash.Type.String
    assert ResourceInfo.relationship(Workspace, :agent).destination == Agent
    assert ResourceInfo.relationship(Workspace, :sessions).destination == Session
    assert workspace_identity.keys == [:user_id, :agent_id]
    refute :environment_id in workspace_identity.keys

    assert ResourceInfo.relationship(Session, :agent).destination == Agent
    assert ResourceInfo.relationship(Session, :agent_version).destination == AgentVersion
    assert ResourceInfo.relationship(Session, :environment).destination == Environment
    assert ResourceInfo.relationship(Session, :workspace).destination == Workspace
    assert Enum.any?(create_action.arguments, &(&1.name == :session_vaults))

    assert Enum.any?(create_action.changes, fn
             %{change: {ManageRelationship, opts}} ->
               opts[:argument] == :session_vaults and
                 opts[:relationship] == :session_vaults and
                 opts[:opts] == [type: :direct_control, order_is_key: :position]

             _ ->
               false
           end)

    assert session_vault_relationship.destination == SessionVault
    assert session_vault_relationship.sort == [position: :asc]
    assert vaults_relationship.type == :many_to_many
    assert vaults_relationship.through == SessionVault
    assert vaults_relationship.destination == Vault
    assert vaults_relationship.source_attribute_on_join_resource == :session_id
    assert vaults_relationship.destination_attribute_on_join_resource == :vault_id

    assert ResourceInfo.relationship(SessionVault, :session).destination == Session
    assert ResourceInfo.relationship(SessionVault, :vault).destination == Vault

    assert Enum.map(ResourceInfo.identities(SessionVault), & &1.name) == [
             :unique_session_vault,
             :unique_session_vault_position
           ]
  end

  test "session lifecycle, thread linkage, and event sequencing use Ash-native fields and identities" do
    archive_action = ResourceInfo.action(Session, :archive, :update)
    soft_delete_action = ResourceInfo.action(Session, :soft_delete, :destroy)

    active_session_identity =
      Enum.find(
        ResourceInfo.identities(Session),
        &(&1.name == :unique_active_session_per_workspace)
      )

    assert ResourceInfo.attribute(Session, :status).type == SessionStatus
    assert ResourceInfo.attribute(Session, :status).default == :idle
    assert ResourceInfo.attribute(Session, :last_processed_event_index).default == -1
    assert ResourceInfo.attribute(Session, :archived_at).type == Ash.Type.UtcDatetimeUsec
    assert ResourceInfo.attribute(Session, :deleted_at).type == Ash.Type.UtcDatetimeUsec
    assert archive_action.accept == []
    assert soft_delete_action.accept == []
    assert soft_delete_action.soft? == true
    assert ResourceInfo.calculation(Session, :active).type == Ash.Type.Boolean
    assert ResourceInfo.calculation(Session, :archived).type == Ash.Type.Boolean
    assert ResourceInfo.calculation(Session, :deleted).type == Ash.Type.Boolean
    assert inspect(active_session_identity.where) =~ ":idle"
    assert inspect(active_session_identity.where) =~ ":running"

    assert AshPostgres.DataLayer.Info.identity_where_to_sql(
             Session,
             :unique_active_session_per_workspace
           ) == "status IN ('idle', 'running')"

    assert ResourceInfo.attribute(SessionThread, :role).type == SessionThreadRole
    assert ResourceInfo.attribute(SessionThread, :status).type == SessionThreadStatus
    assert ResourceInfo.relationship(SessionThread, :parent_thread).destination == SessionThread
    assert ResourceInfo.relationship(SessionThread, :child_threads).destination == SessionThread

    assert Enum.any?(
             ResourceInfo.identities(SessionThread),
             &(&1.name == :unique_primary_thread_per_session)
           )

    assert AshPostgres.DataLayer.Info.identity_where_to_sql(
             SessionThread,
             :unique_primary_thread_per_session
           ) == "role = 'primary'"

    assert ResourceInfo.relationship(Session, :events).sort == [sequence: :asc]
    assert ResourceInfo.relationship(SessionThread, :events).sort == [sequence: :asc]
    assert ResourceInfo.attribute(SessionEvent, :type).type == SessionEventType
    assert ResourceInfo.attribute(SessionEvent, :sequence).default == 0
    assert ResourceInfo.relationship(SessionEvent, :session).destination == Session
    assert ResourceInfo.relationship(SessionEvent, :session_thread).destination == SessionThread
    refute Enum.any?(ResourceInfo.actions(SessionEvent), &(&1.type in [:update, :destroy]))

    assert Enum.any?(
             ResourceInfo.identities(SessionEvent),
             &(&1.name == :unique_session_event_sequence)
           )
  end
end
