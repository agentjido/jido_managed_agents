defmodule JidoManagedAgentsWeb.V1ApiTestHelpers do
  @moduledoc false

  import Plug.Conn

  require Ash.Query

  alias JidoManagedAgents.Accounts.ApiKey
  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Agents.SkillVersion
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.Workspace
  alias JidoManagedAgents.Repo

  def authorized_conn(conn, api_key) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-api-key", api_key)
  end

  def json_conn(conn) do
    put_req_header(conn, "accept", "application/json")
  end

  def create_user!(attrs \\ %{}) do
    attrs = Map.new(attrs)

    user = %User{
      id: Ecto.UUID.generate(),
      email: Map.get(attrs, :email, "user-#{System.unique_integer([:positive])}@example.com"),
      role: Map.get(attrs, :role, :member),
      confirmed_at: Map.get(attrs, :confirmed_at, DateTime.utc_now())
    }

    Repo.query!(
      "INSERT INTO users (id, email, role, confirmed_at) VALUES ($1, $2, $3, $4)",
      [dump_uuid!(user.id), user.email, to_string(user.role), user.confirmed_at]
    )

    user
  end

  def create_api_key!(owner) do
    api_key =
      ApiKey
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: owner.id,
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        },
        actor: owner,
        domain: JidoManagedAgents.Accounts
      )
      |> Ash.create!()

    api_key.__metadata__.plaintext_api_key
  end

  def create_agent!(owner, attrs \\ %{}) do
    attrs = Map.new(attrs)

    agent =
      Agent
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: owner.id,
          name: Map.get(attrs, :name, "agent-#{System.unique_integer([:positive])}"),
          description: Map.get(attrs, :description, "Agent for `/v1` tests"),
          metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
        },
        actor: owner,
        domain: Agents
      )
      |> Ash.create!()

    if Map.get(attrs, :with_version, true) do
      create_agent_version!(owner, agent, attrs)
    end

    agent
  end

  def create_agent_version!(owner, agent, attrs \\ %{}) do
    attrs = Map.new(attrs)

    version_attrs =
      %{
        user_id: owner.id,
        agent_id: agent.id,
        version: Map.get(attrs, :version, 1),
        name: Map.get(attrs, :version_name, agent.name),
        description: Map.get(attrs, :version_description, agent.description),
        model: Map.get(attrs, :model, %{"id" => "claude-sonnet-4-6", "speed" => "standard"}),
        system: Map.get(attrs, :system, "Stay precise."),
        tools: Map.get(attrs, :tools, []),
        mcp_servers: Map.get(attrs, :mcp_servers, []),
        metadata:
          Map.get(
            attrs,
            :version_metadata,
            Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
          )
      }
      |> maybe_put(:agent_version_skills, Map.get(attrs, :agent_version_skills))
      |> maybe_put(
        :agent_version_callable_agents,
        Map.get(attrs, :agent_version_callable_agents)
      )

    AgentVersion
    |> Ash.Changeset.for_create(:create, version_attrs, actor: owner, domain: Agents)
    |> Ash.create!()
  end

  def archive_agent!(owner, agent) do
    agent
    |> Ash.Changeset.for_update(:archive, %{}, actor: owner, domain: Agents)
    |> Ash.update!()
  end

  def latest_agent_version!(owner, agent) do
    Agent
    |> Ash.Query.for_read(:by_id, %{id: agent.id}, actor: owner, domain: Agents)
    |> Ash.Query.load(:latest_version)
    |> Ash.read_one!()
    |> Map.fetch!(:latest_version)
  end

  def create_skill!(owner, attrs \\ %{}) do
    attrs = Map.new(attrs)

    skill =
      Skill
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_id: owner.id,
          type: Map.get(attrs, :type, :custom),
          name: Map.get(attrs, :name, "skill-#{System.unique_integer([:positive])}"),
          description: Map.get(attrs, :description, "Skill for `/v1` tests"),
          metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
        },
        actor: owner,
        domain: Agents
      )
      |> Ash.create!()

    if Map.get(attrs, :with_version, true) do
      create_skill_version!(owner, skill, attrs)
    end

    skill
  end

  def create_skill_version!(owner, skill, attrs \\ %{}) do
    attrs = Map.new(attrs)

    SkillVersion
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        skill_id: skill.id,
        version: Map.get(attrs, :version, 1),
        description: Map.get(attrs, :version_description, skill.description || "Skill version"),
        body: Map.get(attrs, :body, "Use precise domain language."),
        source_path: Map.get(attrs, :source_path),
        allowed_tools: Map.get(attrs, :allowed_tools, []),
        manifest: Map.get(attrs, :manifest, %{}),
        metadata:
          Map.get(
            attrs,
            :version_metadata,
            Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
          )
      },
      actor: owner,
      domain: Agents
    )
    |> Ash.create!()
  end

  def latest_skill_version!(owner, skill) do
    Skill
    |> Ash.Query.for_read(:by_id, %{id: skill.id}, actor: owner, domain: Agents)
    |> Ash.Query.load(:latest_version)
    |> Ash.read_one!()
    |> Map.fetch!(:latest_version)
  end

  def create_environment!(owner, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Environment
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        name: Map.get(attrs, :name, "env-#{System.unique_integer([:positive])}"),
        description: Map.get(attrs, :description, "Environment for `/v1` tests"),
        config:
          Map.get(attrs, :config, %{
            "type" => "cloud",
            "networking" => %{"type" => "restricted"}
          }),
        metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
      },
      actor: owner,
      domain: Agents
    )
    |> Ash.create!()
  end

  def archive_environment!(owner, environment) do
    environment
    |> Ash.Changeset.for_update(:archive, %{}, actor: owner, domain: Agents)
    |> Ash.update!()
  end

  def create_vault!(owner, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Vault
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        name: Map.get(attrs, :name, "vault-#{System.unique_integer([:positive])}"),
        description: Map.get(attrs, :description, "Vault for `/v1` tests"),
        display_metadata: Map.get(attrs, :display_metadata, %{"label" => "Session"}),
        metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
      },
      actor: owner,
      domain: Integrations
    )
    |> Ash.create!()
  end

  def create_credential!(owner, vault, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Credential
    |> Ash.Changeset.for_create(
      :create,
      %{
        vault_id: vault.id,
        type: Map.get(attrs, :type, :static_bearer),
        mcp_server_url:
          Map.get(
            attrs,
            :mcp_server_url,
            "https://mcp-#{System.unique_integer([:positive])}.example.com"
          ),
        token_endpoint: Map.get(attrs, :token_endpoint),
        client_id: Map.get(attrs, :client_id),
        access_token:
          Map.get(attrs, :access_token, "token-#{System.unique_integer([:positive])}"),
        refresh_token: Map.get(attrs, :refresh_token),
        client_secret: Map.get(attrs, :client_secret),
        metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(),
      actor: owner,
      domain: Integrations
    )
    |> Ash.create!()
  end

  def create_workspace!(owner, agent, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Workspace
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        agent_id: agent.id,
        name: Map.get(attrs, :name, "workspace-#{System.unique_integer([:positive])}"),
        backend: Map.get(attrs, :backend, :memory_vfs),
        config: Map.get(attrs, :config, %{"root" => "/tmp/v1-controller-test"}),
        state: Map.get(attrs, :state, "ready"),
        metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
      },
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  def workspace_for!(owner, agent) do
    Workspace
    |> Ash.Query.for_read(:read, %{}, actor: owner, domain: Sessions)
    |> Ash.Query.filter(user_id == ^owner.id and agent_id == ^agent.id)
    |> Ash.read_one!()
  end

  def create_session!(owner, agent, agent_version, environment, workspace, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Session
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        agent_id: agent.id,
        agent_version_id: agent_version.id,
        environment_id: environment.id,
        workspace_id: workspace.id,
        title: Map.get(attrs, :title, "session-#{System.unique_integer([:positive])}"),
        status: Map.get(attrs, :status),
        metadata: Map.get(attrs, :metadata, %{scope: "v1-controller-test"})
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(),
      actor: owner,
      domain: Sessions
    )
    |> Ash.create!()
  end

  def get_session!(owner, id, load \\ []) do
    query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: id}, actor: owner, domain: Sessions)
      |> maybe_load(load)

    Ash.read_one!(query)
  end

  def get_session_with_deleted!(owner, id, load \\ []) do
    query =
      Session
      |> Ash.Query.new(base_filter?: false)
      |> Ash.Query.for_read(:by_id, %{id: id}, actor: owner, domain: Sessions)
      |> maybe_load(load)

    Ash.read_one!(query)
  end

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
