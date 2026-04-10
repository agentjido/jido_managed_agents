defmodule JidoManagedAgents.Sessions.WorkspaceBackend.Adapter do
  @moduledoc """
  Backend adapter contract for opening runtime workspaces.

  Each backend translates a persisted `Sessions.Workspace` row into an opened
  `Jido.Workspace` handle. Callers use `RuntimeWorkspace` and stay insulated
  from backend-specific setup details.
  """

  alias JidoManagedAgents.Sessions.Workspace

  @type backend_module :: module()

  @callback open(Workspace.t()) :: {:ok, Jido.Workspace.t()} | {:error, term()}
end
