defmodule JidoManagedAgents.MCP.Server do
  use Anubis.Server,
    name: "jido-managed-agents",
    version: "0.1.0",
    capabilities: [:tools]

  component(JidoManagedAgents.MCP.Tools.AddNumbers)
end
