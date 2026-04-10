defmodule JidoManagedAgents.Sessions.SessionStatus do
  @moduledoc """
  Persisted lifecycle states for sessions.
  """

  use Ash.Type.Enum,
    values: [
      :idle,
      :running,
      :archived,
      :deleted
    ]
end
