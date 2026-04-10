defmodule JidoManagedAgents.Accounts do
  use Ash.Domain,
    otp_app: :jido_managed_agents

  resources do
    resource JidoManagedAgents.Accounts.Token
    resource JidoManagedAgents.Accounts.User
    resource JidoManagedAgents.Accounts.ApiKey
  end
end
