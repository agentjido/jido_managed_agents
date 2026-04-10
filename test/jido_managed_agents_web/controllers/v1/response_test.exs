defmodule JidoManagedAgentsWeb.V1.ResponseTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgentsWeb.V1.Response

  test "list/2 returns the Anthropic-style list envelope" do
    assert Response.list([%{id: "agt_123"}]) == %{
             data: [%{id: "agt_123"}],
             has_more: false
           }
  end

  test "error/2 returns the Anthropic-style error envelope" do
    assert Response.error("authentication_error", "Invalid x-api-key.") == %{
             error: %{
               type: "authentication_error",
               message: "Invalid x-api-key."
             }
           }
  end
end
