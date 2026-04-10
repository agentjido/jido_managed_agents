defmodule JidoManagedAgents.Authorization.Checks.PlatformAdmin do
  @moduledoc """
  Matches authenticated actors with the `platform_admin` role.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a platform admin"

  @impl true
  def match?(%{role: :platform_admin}, _context, _opts), do: true
  def match?(_, _, _), do: false
end
