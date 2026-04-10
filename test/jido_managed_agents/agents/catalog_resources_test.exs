defmodule JidoManagedAgents.Agents.CatalogResourcesTest do
  use ExUnit.Case, async: true

  alias Ash.Policy.Info
  alias Ash.Resource.Change.ManageRelationship
  alias Ash.Resource.Info, as: ResourceInfo
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.ToolDeclaration
  alias JidoManagedAgents.Authorization.Checks.ReferencedResourceOwnedByActor

  @owner_scoped_resources [
    Agents.Agent,
    Agents.AgentVersion,
    Agents.AgentVersionSkill,
    Agents.AgentVersionCallableAgent,
    Agents.Environment,
    Agents.Skill,
    Agents.SkillVersion
  ]

  test "every mutable catalog resource has explicit user ownership and owner/admin policies" do
    for resource <- @owner_scoped_resources do
      user_relationship = ResourceInfo.relationship(resource, :user)
      create_action = ResourceInfo.action(resource, :create, :create)
      policy_checks = inspect(Info.policies(nil, resource), pretty: true)

      assert user_relationship.type == :belongs_to
      assert user_relationship.destination == JidoManagedAgents.Accounts.User
      assert user_relationship.allow_nil? == false
      assert :user_id in create_action.accept
      assert policy_checks =~ "JidoManagedAgents.Authorization.Checks.PlatformAdmin"
      assert policy_checks =~ "Ash.Policy.Check.RelatingToActor"
      assert policy_checks =~ "Ash.Policy.Check.RelatesToActorVia"
    end
  end

  test "agent versions normalize skills and callable agents through Ash-native relationships" do
    create_action = ResourceInfo.action(Agents.AgentVersion, :create, :create)
    relationships = ResourceInfo.relationships(Agents.AgentVersion)

    assert Enum.any?(create_action.arguments, &(&1.name == :agent_version_skills))
    assert Enum.any?(create_action.arguments, &(&1.name == :agent_version_callable_agents))

    assert_has_manage_relationship(create_action.changes,
      argument: :agent_version_skills,
      relationship: :agent_version_skills,
      opts: [type: :direct_control, order_is_key: :position]
    )

    assert_has_manage_relationship(create_action.changes,
      argument: :agent_version_callable_agents,
      relationship: :agent_version_callable_agents,
      opts: [type: :direct_control, order_is_key: :position]
    )

    assert Enum.find(relationships, &(&1.name == :agent_version_skills)).destination ==
             Agents.AgentVersionSkill

    assert Enum.find(relationships, &(&1.name == :agent_version_callable_agents)).destination ==
             Agents.AgentVersionCallableAgent

    skills_relationship = ResourceInfo.relationship(Agents.AgentVersion, :skills)

    callable_agents_relationship =
      ResourceInfo.relationship(Agents.AgentVersion, :callable_agents)

    assert skills_relationship.type == :many_to_many
    assert skills_relationship.through == Agents.AgentVersionSkill
    assert skills_relationship.source_attribute_on_join_resource == :agent_version_id
    assert skills_relationship.destination_attribute_on_join_resource == :skill_id

    assert callable_agents_relationship.type == :many_to_many
    assert callable_agents_relationship.through == Agents.AgentVersionCallableAgent
    assert callable_agents_relationship.source_attribute_on_join_resource == :agent_version_id

    assert callable_agents_relationship.destination_attribute_on_join_resource ==
             :callable_agent_id
  end

  test "agent versions persist tool declarations through a dedicated Ash type" do
    tools_attribute = ResourceInfo.attribute(Agents.AgentVersion, :tools)

    assert tools_attribute.type == {:array, ToolDeclaration}
    assert tools_attribute.default == []
    assert tools_attribute.allow_nil? == false
  end

  test "relationship resources enforce same-owner graph constraints with explicit create checks" do
    skill_link_checks = create_policy_checks(Agents.AgentVersionSkill)
    callable_link_checks = create_policy_checks(Agents.AgentVersionCallableAgent)
    agent_version_checks = create_policy_checks(Agents.AgentVersion)
    skill_version_checks = create_policy_checks(Agents.SkillVersion)

    assert_has_check(skill_link_checks, ReferencedResourceOwnedByActor,
      attribute: :agent_version_id,
      resource: Agents.AgentVersion,
      domain: Agents
    )

    assert_has_check(skill_link_checks, ReferencedResourceOwnedByActor,
      attribute: :skill_id,
      resource: Agents.Skill,
      domain: Agents
    )

    assert_has_check(skill_link_checks, ReferencedResourceOwnedByActor,
      attribute: :skill_version_id,
      resource: Agents.SkillVersion,
      domain: Agents,
      allow_nil?: true,
      matches: [skill_id: :skill_id]
    )

    assert_has_check(callable_link_checks, ReferencedResourceOwnedByActor,
      attribute: :agent_version_id,
      resource: Agents.AgentVersion,
      domain: Agents
    )

    assert_has_check(callable_link_checks, ReferencedResourceOwnedByActor,
      attribute: :callable_agent_id,
      resource: Agents.Agent,
      domain: Agents
    )

    assert_has_check(callable_link_checks, ReferencedResourceOwnedByActor,
      attribute: :callable_agent_version_id,
      resource: Agents.AgentVersion,
      domain: Agents,
      allow_nil?: true,
      matches: [agent_id: :callable_agent_id]
    )

    assert_has_check(agent_version_checks, ReferencedResourceOwnedByActor,
      attribute: :agent_id,
      resource: Agents.Agent,
      domain: Agents
    )

    assert_has_check(skill_version_checks, ReferencedResourceOwnedByActor,
      attribute: :skill_id,
      resource: Agents.Skill,
      domain: Agents
    )
  end

  test "version linkage and archive behavior are modeled explicitly on catalog resources" do
    agent_aggregates = ResourceInfo.aggregates(Agents.Agent)
    skill_aggregates = ResourceInfo.aggregates(Agents.Skill)
    agent_version_identities = ResourceInfo.identities(Agents.AgentVersion)
    skill_version_identities = ResourceInfo.identities(Agents.SkillVersion)

    assert Enum.any?(agent_aggregates, &(&1.name == :version_count and &1.kind == :count))
    assert Enum.any?(agent_aggregates, &(&1.name == :latest_version_number and &1.kind == :max))
    assert Enum.any?(skill_aggregates, &(&1.name == :version_count and &1.kind == :count))
    assert Enum.any?(skill_aggregates, &(&1.name == :latest_version_number and &1.kind == :max))

    assert Enum.any?(agent_version_identities, &(&1.name == :unique_agent_version_number))
    assert Enum.any?(skill_version_identities, &(&1.name == :unique_skill_version_number))

    for resource <- [Agents.Agent, Agents.Environment, Agents.Skill] do
      archive_action = ResourceInfo.action(resource, :archive, :update)
      archived_calc = ResourceInfo.calculation(resource, :archived)

      assert archive_action.accept == []
      assert archived_calc.type == Ash.Type.Boolean
      assert ResourceInfo.attribute(resource, :archived_at).type == Ash.Type.UtcDatetimeUsec
    end
  end

  defp create_policy_checks(resource) do
    Info.policies(nil, resource)
    |> Enum.filter(&action_policy?(&1, :create))
    |> Enum.flat_map(fn policy ->
      Enum.map(policy.policies, &{&1.check_module, &1.check_opts})
    end)
  end

  defp action_policy?(policy, action_type) do
    Enum.any?(policy.condition, fn
      {Ash.Policy.Check.ActionType, opts} -> action_type in Keyword.fetch!(opts, :type)
      _ -> false
    end)
  end

  defp assert_has_check(checks, check_module, expected_opts) do
    assert Enum.any?(checks, fn
             {^check_module, opts} ->
               Enum.all?(expected_opts, fn {key, value} ->
                 Keyword.get(opts, key) == value
               end)

             _ ->
               false
           end)
  end

  defp assert_has_manage_relationship(changes, expected_opts) do
    assert Enum.any?(changes, fn
             %{change: {ManageRelationship, opts}} ->
               Enum.all?(expected_opts, fn {key, value} ->
                 Keyword.get(opts, key) == value
               end)

             _ ->
               false
           end)
  end
end
