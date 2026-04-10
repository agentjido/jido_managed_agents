defmodule JidoManagedAgents.Agents.AgentDefinitionTest do
  use JidoManagedAgents.DataCase, async: false

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.AgentDefinition
  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @fixture_path Path.expand("../../fixtures/agents/coding-assistant.agent.yaml", __DIR__)

  test "round-trips Anthropic fixture YAML through import, persistence, and export without shape drift" do
    owner = Helpers.create_user!()
    skill = Helpers.create_skill!(owner, %{name: unique_name("research-brief")})
    callable_agent = Helpers.create_agent!(owner, %{name: unique_name("delegate-agent")})

    expected_yaml =
      @fixture_path
      |> File.read!()
      |> String.replace("__SKILL_ID__", skill.id)
      |> String.replace("__CALLABLE_AGENT_ID__", callable_agent.id)

    {:ok, %{} = expected_document} = AgentDefinition.parse_yaml(expected_yaml)

    assert {:ok, agent} = AgentDefinition.create_from_yaml(expected_yaml, actor: owner)

    assert {:ok, %{} = serialized_definition} =
             AgentDefinition.serialize_definition(agent, actor: owner)

    assert {:ok, exported_yaml} = AgentDefinition.export_yaml(agent, actor: owner)
    {:ok, %{} = exported_document} = AgentDefinition.parse_yaml(exported_yaml)

    assert serialized_definition == expected_document
    assert exported_document == expected_document

    assert exported_document["skills"] == [
             %{
               "type" => "custom",
               "skill_id" => skill.id,
               "version" => 1,
               "metadata" => %{"audience" => "platform"}
             }
           ]

    assert exported_document["callable_agents"] == [
             %{
               "type" => "agent",
               "id" => callable_agent.id,
               "version" => 1,
               "metadata" => %{"handoff" => "research"}
             }
           ]
  end

  test "exports the latest definition by default and supports pinned version export" do
    owner = Helpers.create_user!()
    skill = Helpers.create_skill!(owner, %{name: unique_name("pinned-skill")})
    callable_agent = Helpers.create_agent!(owner, %{name: unique_name("pinned-callable")})

    imported_yaml =
      @fixture_path
      |> File.read!()
      |> String.replace("__SKILL_ID__", skill.id)
      |> String.replace("__CALLABLE_AGENT_ID__", callable_agent.id)

    {:ok, agent} = AgentDefinition.create_from_yaml(imported_yaml, actor: owner)

    AgentVersion
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        agent_id: agent.id,
        version: 2,
        name: "Coding Assistant v2",
        description: "Adds review mode.",
        model: %{"provider" => "openai", "id" => "gpt-4o-mini"},
        system: "Review before writing.",
        tools: [
          %{
            "type" => "agent_toolset_20260401",
            "default_config" => %{"permission_policy" => "always_ask"},
            "configs" => %{"edit" => %{"permission_policy" => "always_allow"}}
          }
        ],
        mcp_servers: [%{"type" => "url", "name" => "notes", "url" => "https://example.com/v2"}],
        metadata: %{"team" => "runtime"}
      },
      actor: owner,
      domain: Agents
    )
    |> Ash.create!()

    assert {:ok, latest_yaml} = AgentDefinition.export_yaml(agent, actor: owner)
    {:ok, latest_document} = AgentDefinition.parse_yaml(latest_yaml)

    assert latest_document["name"] == "Coding Assistant v2"
    assert latest_document["model"] == %{"provider" => "openai", "id" => "gpt-4o-mini"}
    assert latest_document["description"] == "Adds review mode."
    assert latest_document["metadata"] == %{"team" => "runtime"}

    assert {:ok, pinned_yaml} = AgentDefinition.export_yaml(agent, actor: owner, version: 1)
    {:ok, pinned_document} = AgentDefinition.parse_yaml(pinned_yaml)
    {:ok, imported_document} = AgentDefinition.parse_yaml(imported_yaml)

    assert pinned_document == imported_document
  end

  test "preserves Anthropic and ReqLLM model forms for YAML export while API serialization stays canonical" do
    owner = Helpers.create_user!()

    cases = [
      {"claude-sonnet-4-6", %{"id" => "claude-sonnet-4-6", "speed" => "standard"}},
      {%{"id" => "claude-opus-4-6", "speed" => "fast"},
       %{"id" => "claude-opus-4-6", "speed" => "fast"}},
      {"openai:gpt-4o", %{"provider" => "openai", "id" => "gpt-4o"}},
      {%{"provider" => "openai", "id" => "gpt-4o-mini"},
       %{"provider" => "openai", "id" => "gpt-4o-mini"}}
    ]

    Enum.each(cases, fn {input_model, expected_response_model} ->
      name = unique_name("model-shape")
      yaml = Ymlr.document!(%{"name" => name, "model" => input_model})

      assert {:ok, agent} = AgentDefinition.create_from_yaml(yaml, actor: owner)
      assert AgentDefinition.serialize_agent(agent).model == expected_response_model
      assert {:ok, exported_yaml} = AgentDefinition.export_yaml(agent, actor: owner)
      {:ok, exported_document} = AgentDefinition.parse_yaml(exported_yaml)

      assert exported_document["model"] == input_model
    end)
  end

  test "recommends the *.agent.yaml filename convention" do
    assert AgentDefinition.recommended_filename("Coding Assistant") ==
             "coding-assistant.agent.yaml"

    assert AgentDefinition.recommended_filename("   ") == "agent.agent.yaml"
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
