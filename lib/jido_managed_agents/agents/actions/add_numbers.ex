defmodule JidoManagedAgents.Agents.Actions.AddNumbers do
  use Jido.Action,
    name: "add_numbers",
    description: "Add two integers together",
    schema: [
      a: [type: :integer, required: true],
      b: [type: :integer, required: true]
    ]

  @impl true
  def run(%{a: a, b: b}, _context) do
    {:ok, %{sum: a + b}}
  end
end
