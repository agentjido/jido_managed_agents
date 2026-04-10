defmodule JidoManagedAgents.Authorization do
  @moduledoc """
  Shared Ash policy patterns for the managed-agents platform.

  v1 authorization stays intentionally small:

  - owner-scoped access for mutable resources
  - `platform_admin` bypass access for platform operations
  - API keys authenticate as their owning user, so they inherit that user's
    policies instead of introducing a second actor model
  """

  defmacro platform_admin_override do
    quote do
      bypass JidoManagedAgents.Authorization.Checks.PlatformAdmin do
        authorize_if always()
      end
    end
  end

  defmacro owner_access_policies(owner_relationship \\ :user) do
    quote bind_quoted: [owner_relationship: owner_relationship] do
      policy action_type(:create) do
        authorize_if relating_to_actor(owner_relationship)
      end

      policy action_type(:read) do
        authorize_if relates_to_actor_via(owner_relationship)
      end

      policy action_type([:update, :destroy]) do
        authorize_if relates_to_actor_via(owner_relationship)
      end
    end
  end

  defmacro owner_or_admin_policies(owner_relationship \\ :user) do
    quote bind_quoted: [owner_relationship: owner_relationship] do
      require JidoManagedAgents.Authorization

      JidoManagedAgents.Authorization.platform_admin_override()
      JidoManagedAgents.Authorization.owner_access_policies(owner_relationship)
    end
  end
end
