defmodule JidoManagedAgents.Integrations.CredentialType do
  @moduledoc """
  Persisted credential types supported by the integrations secret model.
  """

  use Ash.Type.Enum,
    values: [
      :mcp_oauth,
      :static_bearer
    ]
end
