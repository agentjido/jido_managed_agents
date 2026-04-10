defmodule JidoManagedAgents.Agents.AgentDefinitionHelpersTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentDefinition
  alias JidoManagedAgents.Agents.AgentModel
  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Agents.AgentVersionCallableAgent
  alias JidoManagedAgents.Agents.AgentVersionSkill
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Agents.SkillVersion

  test "supported model forms preserve export shape and keep canonical API response maps" do
    cases = [
      {"claude-sonnet-4-6", %{"id" => "claude-sonnet-4-6", "speed" => "standard"}},
      {%{"id" => "claude-opus-4-6", "speed" => "fast"},
       %{"id" => "claude-opus-4-6", "speed" => "fast"}},
      {"openai:gpt-4o", %{"provider" => "openai", "id" => "gpt-4o"}},
      {%{"provider" => "openai", "id" => "gpt-4o-mini"},
       %{"provider" => "openai", "id" => "gpt-4o-mini"}}
    ]

    Enum.each(cases, fn {input_model, expected_response_model} ->
      assert {:ok, normalized_model} = AgentModel.normalize(input_model)
      assert AgentModel.serialize_for_response(normalized_model) == expected_response_model
      assert AgentModel.serialize_for_definition(normalized_model) == input_model
    end)
  end

  test "normalize_create_payload keeps nested Anthropic-compatible structures intact" do
    payload = %{
      "name" => "Coding Assistant",
      "model" => %{"id" => "claude-opus-4-6", "speed" => "fast"},
      "system" => "Stay precise.",
      "tools" => [
        %{
          "type" => "agent_toolset_20260401",
          "configs" => %{"write" => %{"permission_policy" => "always_allow"}}
        }
      ],
      "mcp_servers" => [
        %{
          "type" => "url",
          "name" => "docs",
          "url" => "https://example.com/mcp",
          "headers" => %{"x-scope" => "engineering"}
        }
      ],
      "description" => "Writes production code.",
      "metadata" => %{"team" => "platform", "delivery" => %{"tier" => "gold"}}
    }

    assert {:ok, normalized_payload} = AgentDefinition.normalize_create_payload(payload)

    assert normalized_payload.agent == %{
             name: "Coding Assistant",
             description: "Writes production code.",
             metadata: %{"team" => "platform", "delivery" => %{"tier" => "gold"}}
           }

    assert normalized_payload.version.model == %{
             "id" => "claude-opus-4-6",
             "speed" => "fast",
             "__serialization_shape" => "anthropic_object"
           }

    assert normalized_payload.version.tools == [
             %{
               "type" => "agent_toolset_20260401",
               "default_config" => %{"permission_policy" => "always_ask"},
               "configs" => %{"write" => %{"permission_policy" => "always_allow"}}
             }
           ]

    assert normalized_payload.version.mcp_servers == [
             %{
               "type" => "url",
               "name" => "docs",
               "url" => "https://example.com/mcp",
               "headers" => %{"x-scope" => "engineering"}
             }
           ]
  end

  test "serialize_agent emits canonical API shapes and keeps link metadata" do
    {:ok, model} = AgentModel.normalize("openai:gpt-4o")

    agent =
      struct(Agent, %{
        id: "agent-123",
        name: "Coding Assistant",
        description: "Writes production code.",
        metadata: %{"team" => "platform"},
        archived_at: nil,
        created_at: ~U[2026-04-09 17:00:00Z],
        updated_at: ~U[2026-04-09 17:00:00Z],
        latest_version:
          struct(AgentVersion, %{
            id: "version-123",
            version: 2,
            name: "Coding Assistant v2",
            model: model,
            system: "Review before writing.",
            tools: [
              %{
                "type" => "agent_toolset_20260401",
                "default_config" => %{"permission_policy" => "always_ask"},
                "configs" => %{}
              }
            ],
            mcp_servers: [
              %{"type" => "url", "name" => "docs", "url" => "https://example.com/mcp"}
            ],
            description: "Adds review mode.",
            metadata: %{"team" => "runtime"},
            created_at: ~U[2026-04-09 17:00:00Z],
            updated_at: ~U[2026-04-09 17:05:00Z],
            agent_version_skills: [
              struct(AgentVersionSkill, %{
                skill_id: "skill-123",
                position: 0,
                metadata: %{"audience" => "platform"},
                skill: struct(Skill, %{type: :custom}),
                skill_version: struct(SkillVersion, %{version: 3})
              })
            ],
            agent_version_callable_agents: [
              struct(AgentVersionCallableAgent, %{
                callable_agent_id: "agent-456",
                position: 0,
                metadata: %{"handoff" => "research"},
                callable_agent_version: struct(AgentVersion, %{version: 4})
              })
            ]
          })
      })

    assert response = AgentDefinition.serialize_agent(agent)

    assert response.model == %{"provider" => "openai", "id" => "gpt-4o"}

    assert response.skills == [
             %{
               "type" => "custom",
               "skill_id" => "skill-123",
               "version" => 3,
               "metadata" => %{"audience" => "platform"}
             }
           ]

    assert response.callable_agents == [
             %{
               "type" => "agent",
               "id" => "agent-456",
               "version" => 4,
               "metadata" => %{"handoff" => "research"}
             }
           ]
  end
end
