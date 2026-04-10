defmodule JidoManagedAgents.Sessions.SessionThreadRole do
  @moduledoc """
  Roles for session threads in the persisted execution graph.
  """

  use Ash.Type.Enum,
    values: [
      :primary,
      :delegate
    ]
end
