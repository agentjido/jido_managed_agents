defmodule JidoManagedAgents.MCP.Tools.AddNumbers do
  use Anubis.Server.Component, type: :tool

  @moduledoc "Add two integers together."

  alias Anubis.Server.Response

  schema do
    field :a, :integer, required: true, description: "The first integer"
    field :b, :integer, required: true, description: "The second integer"
  end

  def execute(%{a: a, b: b}, frame) do
    {:reply, Response.tool() |> Response.structured(%{sum: a + b}), frame}
  end

  def execute(%{"a" => a, "b" => b}, frame), do: execute(%{a: a, b: b}, frame)
end
