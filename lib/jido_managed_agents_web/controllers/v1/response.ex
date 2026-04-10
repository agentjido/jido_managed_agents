defmodule JidoManagedAgentsWeb.V1.Response do
  @moduledoc """
  Shared Anthropic-style response envelopes for `/v1` controllers.
  """

  @spec list([map()], keyword()) :: map()
  def list(data, opts \\ []) when is_list(data) do
    %{
      data: data,
      has_more: Keyword.get(opts, :has_more, false)
    }
  end

  @spec error(String.t(), String.t()) :: map()
  def error(type, message) when is_binary(type) and is_binary(message) do
    %{
      error: %{
        type: type,
        message: message
      }
    }
  end
end
