defmodule JidoManagedAgents.Sessions.WorkspaceBackend.MemoryVFS do
  @moduledoc """
  Opens a runtime workspace backed by Jido's in-memory VFS.
  """

  @behaviour JidoManagedAgents.Sessions.WorkspaceBackend.Adapter

  alias JidoManagedAgents.Sessions.Workspace

  @impl true
  def open(%Workspace{id: workspace_id}) do
    case Jido.Workspace.new(id: workspace_id) do
      %Jido.Workspace.Workspace{} = workspace -> {:ok, workspace}
      {:error, :already_exists} -> {:ok, %Jido.Workspace.Workspace{id: workspace_id}}
      {:error, reason} -> {:error, reason}
    end
  end
end
