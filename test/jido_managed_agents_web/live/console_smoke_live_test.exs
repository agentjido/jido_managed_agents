defmodule JidoManagedAgentsWeb.ConsoleSmokeLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  import JidoManagedAgentsWeb.V1ApiTestHelpers

  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session

  test "protected console pages require an authenticated user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/agents")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/agents/unknown")
  end

  test "overview renders pending sessions and recent activity for the current user", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    agent =
      create_agent!(user, %{
        name: "Release Analyst",
        description: "Investigates delivery regressions."
      })

    environment = create_environment!(user, %{name: "Ops Sandbox"})
    workspace = create_workspace!(user, agent)
    version = latest_agent_version!(user, agent)

    session =
      create_session!(user, agent, version, environment, workspace, %{
        title: "Awaiting Release Approval"
      })
      |> mark_requires_action!(user)

    other = create_user!()
    other_agent = create_agent!(other, %{name: "Other User Agent"})
    other_environment = create_environment!(other, %{name: "Other User Environment"})
    other_workspace = create_workspace!(other, other_agent)
    other_version = latest_agent_version!(other, other_agent)

    _other_session =
      create_session!(other, other_agent, other_version, other_environment, other_workspace, %{
        title: "Other User Session"
      })
      |> mark_requires_action!(other)

    {:ok, view, html} = live(conn, ~p"/console")

    assert html =~ "Overview"
    assert html =~ "Sessions waiting on you"
    assert html =~ agent.name
    assert html =~ session.title
    refute html =~ "Other User Session"
    refute html =~ "Other User Agent"

    assert has_element?(view, "a[href='/console/agents/new']")
    assert has_element?(view, "a[href='/console/sessions/#{session.id}']")
    assert has_element?(view, "a[href='/console/agents/#{agent.id}']")
  end

  test "agents library filters by search and archived state", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    active_agent =
      create_agent!(user, %{
        name: "Research Coordinator",
        description: "Coordinates release research."
      })

    archived_agent =
      create_agent!(user, %{
        name: "Archived Reviewer",
        description: "Legacy review workflow."
      })

    archive_agent!(user, archived_agent)

    other = create_user!()
    _other_agent = create_agent!(other, %{name: "Other User Agent"})

    {:ok, view, html} = live(conn, ~p"/console/agents")

    assert html =~ "Agents"
    assert html =~ active_agent.name
    assert html =~ archived_agent.name
    refute html =~ "Other User Agent"

    render_change(element(view, "#agent-filters"), %{
      "filters" => %{"search" => "research", "status" => "all"}
    })

    html = render(view)

    assert html =~ active_agent.name
    refute html =~ archived_agent.name

    render_change(element(view, "#agent-filters"), %{
      "filters" => %{"search" => "", "status" => "archived"}
    })

    html = render(view)

    refute html =~ active_agent.name
    assert html =~ archived_agent.name
  end

  test "agent detail supports version switching and session tab rendering", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    agent =
      create_agent!(user, %{
        name: "Detail Agent",
        description: "Investigates incidents in depth."
      })

    _version_2 =
      create_agent_version!(user, agent, %{
        version: 2,
        version_name: "Detail Agent",
        system: "Be concise and cite evidence.",
        tools: [
          %{
            "type" => "agent_toolset_20260401",
            "default_config" => %{"permission_policy" => "always_ask"},
            "configs" => %{"bash" => %{"permission_policy" => "always_allow"}}
          }
        ],
        mcp_servers: [
          %{
            "name" => "docs",
            "type" => "url",
            "url" => "https://docs.example.com/mcp"
          }
        ],
        version_metadata: %{"team" => "platform"}
      })

    environment = create_environment!(user, %{name: "Detail Sandbox"})
    workspace = create_workspace!(user, agent)
    version = latest_agent_version!(user, agent)

    session =
      create_session!(user, agent, version, environment, workspace, %{
        title: "Detail Session"
      })
      |> mark_requires_action!(user)

    {:ok, view, html} = live(conn, ~p"/console/agents/#{agent.id}")

    assert html =~ agent.name
    assert html =~ "Be concise and cite evidence."
    assert html =~ "1 attached"
    assert html =~ "1 connected"
    assert html =~ "https://docs.example.com/mcp"
    assert html =~ "No skills"
    assert html =~ "No callable agents"

    render_change(element(view, "form"), %{"version" => %{"value" => "1"}})
    assert_patch(view, ~p"/console/agents/#{agent.id}?version=1&tab=agent")
    assert render(view) =~ "Stay precise."

    render_click(element(view, "a[href='/console/agents/#{agent.id}?version=1&tab=sessions']"))
    assert_patch(view, ~p"/console/agents/#{agent.id}?version=1&tab=sessions")

    html = render(view)

    assert html =~ "Open a conversation with this agent"
    assert html =~ "Recent Sessions"
    assert html =~ session.title
    assert has_element?(view, "a[href='/console/sessions/#{session.id}']")
  end

  defp mark_requires_action!(%Session{} = session, user) do
    session
    |> Ash.Changeset.for_update(
      :update,
      %{
        stop_reason: %{"type" => "requires_action", "event_ids" => ["evt_approval_1"]}
      },
      actor: user,
      domain: Sessions
    )
    |> Ash.update!()
  end
end
