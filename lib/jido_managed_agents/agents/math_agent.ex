defmodule JidoManagedAgents.Agents.MathAgent do
  use Jido.AI.Agent,
    name: "math_agent",
    description: "A local Jido.AI agent for arithmetic tool calls",
    model: :fast,
    tools: [JidoManagedAgents.Agents.Actions.AddNumbers],
    system_prompt: "Use the available tools for arithmetic and return concise answers."
end
