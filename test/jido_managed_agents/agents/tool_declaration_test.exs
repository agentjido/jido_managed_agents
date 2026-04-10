defmodule JidoManagedAgents.Agents.ToolDeclarationTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgents.Agents.ToolDeclaration

  test "normalizes built-in, MCP, and custom tool declarations with permission defaults" do
    assert {:ok,
            [
              %{
                "type" => "agent_toolset_20260401",
                "default_config" => %{"permission_policy" => "always_ask"},
                "configs" => %{
                  "write" => %{"permission_policy" => "always_allow"},
                  "web_search" => %{"enabled" => false}
                }
              },
              %{
                "type" => "mcp_toolset",
                "mcp_server_name" => "docs",
                "permission_policy" => "always_ask"
              },
              %{
                "type" => "custom",
                "name" => "lookup_release",
                "description" => "Looks up release notes.",
                "input_schema" => %{
                  "type" => "object",
                  "properties" => %{"package" => %{"type" => "string"}}
                },
                "permission_policy" => "always_ask"
              }
            ]} =
             ToolDeclaration.normalize_many([
               %{
                 type: "agent_toolset_20260401",
                 configs: %{
                   write: %{permission_policy: "always_allow"},
                   web_search: %{enabled: false}
                 }
               },
               %{"type" => "mcp_toolset", "mcp_server_name" => "docs"},
               %{
                 "type" => "custom",
                 "name" => "lookup_release",
                 "description" => "Looks up release notes.",
                 "input_schema" => %{
                   type: "object",
                   properties: %{package: %{type: "string"}}
                 }
               }
             ])
  end

  test "rejects unsupported built-in tool configs with an indexed path" do
    assert {:error, details} =
             ToolDeclaration.normalize_many([
               %{
                 "type" => "agent_toolset_20260401",
                 "configs" => %{"deploy" => %{"enabled" => false}}
               }
             ])

    assert details[:path] == [0, "configs", "deploy"]
    assert details[:message] == "is not a supported built-in tool."

    assert ToolDeclaration.format_error("tools", details) ==
             "tools.0.configs.deploy is not a supported built-in tool."
  end

  test "rejects invalid permission policies" do
    assert {:error, details} =
             ToolDeclaration.normalize_many([
               %{
                 "type" => "custom",
                 "name" => "lookup_release",
                 "description" => "Looks up release notes.",
                 "input_schema" => %{"type" => "object"},
                 "permission_policy" => "sometimes_allow"
               }
             ])

    assert details[:path] == [0, "permission_policy"]
    assert details[:message] == "must be one of always_allow or always_ask."
  end
end
