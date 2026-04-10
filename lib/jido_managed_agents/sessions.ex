defmodule JidoManagedAgents.Sessions do
  @moduledoc """
  Ash domain boundary for runtime execution state.

  This domain owns the persisted runtime execution model: workspaces, sessions,
  ordered session-vault joins, threads, and events.
  """

  use Ash.Domain,
    otp_app: :jido_managed_agents

  resources do
    resource JidoManagedAgents.Sessions.Workspace do
      define :create_workspace, action: :create
      define :update_workspace, action: :update
      define :destroy_workspace, action: :destroy
      define :get_workspace, action: :by_id, args: [:id]
      define :list_workspaces, action: :read
    end

    resource JidoManagedAgents.Sessions.Session do
      define :create_session, action: :create
      define :update_session, action: :update
      define :archive_session, action: :archive
      define :soft_delete_session, action: :soft_delete
      define :get_session, action: :by_id, args: [:id]
      define :list_sessions, action: :read
    end

    resource JidoManagedAgents.Sessions.SessionVault do
      define :create_session_vault, action: :create
      define :update_session_vault, action: :update
      define :destroy_session_vault, action: :destroy
      define :get_session_vault, action: :by_id, args: [:id]
      define :list_session_vaults, action: :read
    end

    resource JidoManagedAgents.Sessions.SessionThread do
      define :create_session_thread, action: :create
      define :update_session_thread, action: :update
      define :destroy_session_thread, action: :destroy
      define :get_session_thread, action: :by_id, args: [:id]
      define :list_session_threads, action: :read
    end

    resource JidoManagedAgents.Sessions.SessionEvent do
      define :create_session_event, action: :create
      define :get_session_event, action: :by_id, args: [:id]
      define :list_session_events, action: :read
    end
  end
end
