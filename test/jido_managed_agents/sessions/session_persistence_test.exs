defmodule JidoManagedAgents.Sessions.SessionPersistenceTest do
  use JidoManagedAgents.DataCase, async: false

  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.{Agent, AgentVersion, Environment}
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.{Session, SessionVault, Workspace}

  test "workspace resolution, reuse, ordered vault linkage, and active-session exclusivity are enforced in storage" do
    owner = create_user!()
    agent = create_agent!(owner)
    agent_version = create_agent_version!(owner, agent)
    environment = create_environment!(owner)
    alternate_environment = create_environment!(owner)
    workspace = create_workspace!(owner, agent)
    session = create_session!(owner, agent, agent_version, environment, nil)
    vault_one = create_vault!(owner)
    vault_two = create_vault!(owner)

    assert session.workspace_id == workspace.id
    assert session.environment_id == environment.id

    assert {:error, duplicate_workspace_error} = create_workspace(owner, agent)
    assert inspect(duplicate_workspace_error) =~ "unique_workspace_per_user_agent"

    assert {:error, active_session_error} =
             create_session(owner, agent, agent_version, environment, nil)

    assert Exception.message(active_session_error) =~ "workspace already has an active session"

    archived_session =
      create_session!(owner, agent, agent_version, alternate_environment, nil, %{
        status: :archived
      })

    assert archived_session.status == :archived
    assert archived_session.workspace_id == workspace.id
    assert archived_session.environment_id == alternate_environment.id

    create_session_vault!(owner, session, vault_one, %{position: 1})
    create_session_vault!(owner, session, vault_two, %{position: 0})

    loaded_session =
      Ash.load!(session, [:session_vaults, :threads], actor: owner, domain: Sessions)

    assert Enum.map(loaded_session.session_vaults, &{&1.position, &1.vault_id}) == [
             {0, vault_two.id},
             {1, vault_one.id}
           ]

    assert Enum.map(loaded_session.threads, &{&1.role, &1.agent_id, &1.agent_version_id}) == [
             {:primary, agent.id, agent_version.id}
           ]
  end

  test "sessions reject an explicit workspace that does not match the resolved agent workspace" do
    owner = create_user!()
    agent = create_agent!(owner)
    other_agent = create_agent!(owner)
    agent_version = create_agent_version!(owner, agent)
    environment = create_environment!(owner)
    workspace = create_workspace!(owner, agent)
    other_workspace = create_workspace!(owner, other_agent)

    assert workspace.agent_id == agent.id
    assert other_workspace.agent_id == other_agent.id

    assert {:error, error} =
             create_session(owner, agent, agent_version, environment, other_workspace)

    assert Exception.message(error) =~
             "workspace must match the resolved workspace for this user and agent"
  end

  test "soft delete preserves session history, hides the row from default reads, and frees the workspace" do
    owner = create_user!()
    agent = create_agent!(owner)
    agent_version = create_agent_version!(owner, agent)
    environment = create_environment!(owner)
    workspace = create_workspace!(owner, agent)
    session = create_session!(owner, agent, agent_version, environment, workspace)

    deleted_session =
      Ash.destroy!(session,
        action: :soft_delete,
        actor: owner,
        domain: Sessions,
        return_destroyed?: true
      )

    assert deleted_session.status == :deleted
    assert %DateTime{} = deleted_session.deleted_at

    assert %{
             rows: [["deleted", deleted_at]]
           } =
             Repo.query!(
               """
               SELECT status, deleted_at
               FROM sessions
               WHERE id = $1
               """,
               [dump_uuid!(session.id)]
             )

    assert not is_nil(deleted_at)

    deleted_query =
      Session
      |> Ash.Query.for_read(:by_id, %{id: session.id}, actor: owner, domain: Sessions)
      |> Ash.read_one!()

    assert deleted_query == nil

    replacement_session = create_session!(owner, agent, agent_version, environment, workspace)
    assert replacement_session.status == :idle
  end

  test "session idle and running status transitions are persisted as chronological events" do
    owner = create_user!()
    agent = create_agent!(owner)
    agent_version = create_agent_version!(owner, agent)
    environment = create_environment!(owner)
    workspace = create_workspace!(owner, agent)

    session = create_session!(owner, agent, agent_version, environment, workspace)
    loaded_session = Ash.load!(session, :events, actor: owner, domain: Sessions)

    assert Enum.map(loaded_session.events, &{&1.sequence, &1.type, &1.payload}) == [
             {0, "session.status_idle", %{"status" => "idle"}}
           ]

    running_session =
      session
      |> Ash.Changeset.for_update(:update, %{status: :running}, actor: owner, domain: Sessions)
      |> Ash.update!()

    running_session = Ash.load!(running_session, :events, actor: owner, domain: Sessions)

    assert Enum.map(running_session.events, &{&1.sequence, &1.type, &1.payload}) == [
             {0, "session.status_idle", %{"status" => "idle"}},
             {1, "session.status_running", %{"status" => "running"}}
           ]
  end

  test "archived agents cannot be used for new sessions" do
    owner = create_user!()
    agent = create_agent!(owner)
    agent_version = create_agent_version!(owner, agent)
    environment = create_environment!(owner)
    workspace = create_workspace!(owner, agent)

    archived_agent =
      agent
      |> Ash.Changeset.for_update(:archive, %{}, actor: owner, domain: Agents)
      |> Ash.update!()

    assert %DateTime{} = archived_agent.archived_at

    assert {:error, error} =
             create_session(owner, archived_agent, agent_version, environment, workspace)

    assert Exception.message(error) =~ "Archived agents cannot be used for new sessions."
  end

  defp create_user! do
    user = %User{
      id: Ecto.UUID.generate(),
      email: "session-user-#{System.unique_integer([:positive])}@example.com",
      role: :member
    }

    Repo.query!(
      "INSERT INTO users (id, email, role) VALUES ($1, $2, $3)",
      [dump_uuid!(user.id), user.email, to_string(user.role)]
    )

    user
  end

  defp create_agent!(user) do
    Agent
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        name: "agent-#{System.unique_integer([:positive])}",
        description: "Runtime agent",
        metadata: %{scope: "session-test"}
      },
      actor: user,
      domain: Agents
    )
    |> Ash.create!()
  end

  defp create_agent_version!(user, agent) do
    AgentVersion
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        agent_id: agent.id,
        version: 1,
        name: "#{agent.name} v1",
        description: "Current version",
        model: %{provider: "anthropic", name: "claude-sonnet"},
        system: "Stay precise.",
        tools: [],
        mcp_servers: [],
        metadata: %{release: 1}
      },
      actor: user,
      domain: Agents
    )
    |> Ash.create!()
  end

  defp create_environment!(user) do
    Environment
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        name: "env-#{System.unique_integer([:positive])}",
        description: "Session environment",
        config: %{type: "cloud", networking: %{type: "restricted"}},
        metadata: %{scope: "session-test"}
      },
      actor: user,
      domain: Agents
    )
    |> Ash.create!()
  end

  defp create_vault!(user) do
    Vault
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        name: "vault-#{System.unique_integer([:positive])}",
        description: "Session vault",
        display_metadata: %{label: "Session"},
        metadata: %{scope: "session-test"}
      },
      actor: user,
      domain: Integrations
    )
    |> Ash.create!()
  end

  defp create_workspace!(user, agent, attrs \\ %{}) do
    user
    |> create_workspace(agent, attrs)
    |> case do
      {:ok, workspace} -> workspace
      {:error, error} -> raise inspect(error)
    end
  end

  defp create_workspace(user, agent, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      agent_id: agent.id,
      name: "workspace-#{System.unique_integer([:positive])}",
      backend: :memory_vfs,
      config: %{root: "/tmp/session-test"},
      state: "ready",
      metadata: %{scope: "session-test"}
    }

    Workspace
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)),
      actor: user,
      domain: Sessions
    )
    |> Ash.create()
  end

  defp create_session!(user, agent, agent_version, environment, workspace, attrs \\ %{}) do
    user
    |> create_session(agent, agent_version, environment, workspace, attrs)
    |> case do
      {:ok, session} -> session
      {:error, error} -> raise Exception.message(error)
    end
  end

  defp create_session(user, agent, agent_version, environment, workspace, attrs \\ %{}) do
    defaults =
      %{
        user_id: user.id,
        agent_id: agent.id,
        agent_version_id: agent_version.id,
        environment_id: environment.id,
        title: "session-#{System.unique_integer([:positive])}",
        metadata: %{scope: "session-test"}
      }
      |> maybe_put_workspace_id(workspace)

    Session
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)),
      actor: user,
      domain: Sessions
    )
    |> Ash.create()
  end

  defp maybe_put_workspace_id(attrs, nil), do: attrs
  defp maybe_put_workspace_id(attrs, workspace), do: Map.put(attrs, :workspace_id, workspace.id)

  defp create_session_vault!(user, session, vault, attrs) do
    defaults = %{
      user_id: user.id,
      session_id: session.id,
      vault_id: vault.id,
      position: 0,
      metadata: %{scope: "session-test"}
    }

    SessionVault
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)),
      actor: user,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
