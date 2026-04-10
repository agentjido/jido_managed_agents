defmodule JidoManagedAgents.Sessions.SessionLock do
  @moduledoc false

  @spec with_lock(String.t(), (-> result)) :: result when result: var
  def with_lock(session_id, fun) when is_binary(session_id) and is_function(fun, 0) do
    :global.trans(lock_id(session_id), fun)
  end

  defp lock_id(session_id), do: {__MODULE__, session_id}
end
