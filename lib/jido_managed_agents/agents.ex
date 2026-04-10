defmodule JidoManagedAgents.Agents do
  @moduledoc """
  Ash domain boundary for the managed-agents catalog.

  This domain owns the persisted catalog resources for agents, environments,
  skills, and their normalized version/link records.
  """

  use Ash.Domain,
    otp_app: :jido_managed_agents

  resources do
    resource JidoManagedAgents.Agents.Agent do
      define :create_agent, action: :create
      define :update_agent, action: :update
      define :archive_agent, action: :archive
      define :destroy_agent, action: :destroy
      define :get_agent, action: :by_id, args: [:id]
      define :list_agents, action: :read
    end

    resource JidoManagedAgents.Agents.AgentVersion do
      define :create_agent_version, action: :create
      define :get_agent_version, action: :by_id, args: [:id]
      define :list_agent_versions, action: :read
    end

    resource JidoManagedAgents.Agents.AgentVersionSkill do
      define :create_agent_version_skill, action: :create
      define :update_agent_version_skill, action: :update
      define :destroy_agent_version_skill, action: :destroy
      define :get_agent_version_skill, action: :by_id, args: [:id]
      define :list_agent_version_skills, action: :read
    end

    resource JidoManagedAgents.Agents.AgentVersionCallableAgent do
      define :create_agent_version_callable_agent, action: :create
      define :update_agent_version_callable_agent, action: :update
      define :destroy_agent_version_callable_agent, action: :destroy
      define :get_agent_version_callable_agent, action: :by_id, args: [:id]
      define :list_agent_version_callable_agents, action: :read
    end

    resource JidoManagedAgents.Agents.Environment do
      define :create_environment, action: :create
      define :update_environment, action: :update
      define :archive_environment, action: :archive
      define :destroy_environment, action: :destroy
      define :get_environment, action: :by_id, args: [:id]
      define :list_environments, action: :read
    end

    resource JidoManagedAgents.Agents.Skill do
      define :create_skill, action: :create
      define :update_skill, action: :update
      define :archive_skill, action: :archive
      define :destroy_skill, action: :destroy
      define :get_skill, action: :by_id, args: [:id]
      define :list_skills, action: :read
    end

    resource JidoManagedAgents.Agents.SkillVersion do
      define :create_skill_version, action: :create
      define :get_skill_version, action: :by_id, args: [:id]
      define :list_skill_versions, action: :read
    end
  end
end
