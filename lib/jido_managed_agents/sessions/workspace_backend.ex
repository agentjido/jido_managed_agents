defmodule JidoManagedAgents.Sessions.WorkspaceBackend do
  @moduledoc """
  Persisted workspace backends supported by the v1 execution model.
  """

  use Ash.Type.Enum,
    values: [
      :memory_vfs,
      :local_vfs
    ]
end
