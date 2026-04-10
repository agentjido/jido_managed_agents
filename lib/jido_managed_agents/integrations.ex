defmodule JidoManagedAgents.Integrations do
  @moduledoc """
  Ash domain boundary for secret-backed integration resources.

  This domain will own vaults and credentials, keeping encrypted integration
  data separate from the agent catalog and runtime session model. The intended
  split and conventions live in `JidoManagedAgents.Platform.Architecture`.
  """

  use Ash.Domain,
    otp_app: :jido_managed_agents

  resources do
    resource JidoManagedAgents.Integrations.Vault
    resource JidoManagedAgents.Integrations.Credential
  end
end
