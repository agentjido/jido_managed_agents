defmodule JidoManagedAgents.Accounts.UserRole do
  @moduledoc """
  Minimal v1 role model for authenticated users.
  """

  use Ash.Type.Enum,
    values: [
      :member,
      :platform_admin
    ]
end
