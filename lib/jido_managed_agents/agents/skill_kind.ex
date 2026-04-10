defmodule JidoManagedAgents.Agents.SkillKind do
  @moduledoc """
  The persisted skill kinds supported by the catalog registry.
  """

  use Ash.Type.Enum,
    values: [
      :custom,
      :anthropic
    ]
end
