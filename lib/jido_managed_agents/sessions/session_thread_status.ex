defmodule JidoManagedAgents.Sessions.SessionThreadStatus do
  @moduledoc """
  Persisted lifecycle states for session threads.
  """

  use Ash.Type.Enum,
    values: [
      :idle,
      :running,
      :archived
    ]
end
