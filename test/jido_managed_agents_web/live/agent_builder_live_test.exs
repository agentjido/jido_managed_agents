defmodule JidoManagedAgentsWeb.AgentBuilderLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  import JidoManagedAgentsWeb.V1ApiTestHelpers

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session

  setup do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_api_key = Application.get_env(:req_llm, :anthropic_api_key)

    on_exit(fn ->
      if previous_runtime == nil do
        Application.delete_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)
      else
        Application.put_env(
          :jido_managed_agents,
          JidoManagedAgents.Sessions.SessionRuntime,
          previous_runtime
        )
      end

      if previous_api_key == nil do
        Application.delete_env(:req_llm, :anthropic_api_key)
      else
        Application.put_env(:req_llm, :anthropic_api_key, previous_api_key)
      end
    end)

    :ok
  end

  test "requires an authenticated user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/console/agents/new")
  end

  test "renders the builder sections and live previews", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/console/agents/new")

    assert has_element?(view, "#agent-builder-form")
    assert has_element?(view, "#add-tool-button")
    assert has_element?(view, "#add-mcp-server-button")
    assert has_element?(view, "#add-skill-button")
    assert has_element?(view, "#add-callable-agent-button")
    assert has_element?(view, "#api-preview")
    assert has_element?(view, "#yaml-preview")

    render_change(element(view, "#agent-builder-form"), %{
      "agent" => builder_params("Research Coordinator")
    })

    assert element(view, "#api-preview") |> render() =~
             "&quot;name&quot;: &quot;Research Coordinator&quot;"

    assert element(view, "#yaml-preview") |> render() =~ "name: Research Coordinator"
  end

  test "creates a new agent and updates an existing agent version", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, create_view, _html} = live(conn, ~p"/console/agents/new")

    render_submit(element(create_view, "#agent-builder-form"), %{
      "agent" => builder_params("Research Coordinator")
    })

    created_agent = get_agent_by_name!(user, "Research Coordinator")

    {:ok, edit_view, _html} = live(conn, ~p"/console/agents/#{created_agent.id}/edit")

    render_submit(element(edit_view, "#agent-builder-form"), %{
      "agent" => builder_params("Research Coordinator v2")
    })

    updated_agent =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: created_agent.id}, actor: user, domain: Agents)
      |> Ash.Query.load(AgentCatalog.latest_version_load())
      |> Ash.read_one!()

    assert updated_agent.latest_version.version == 2
    assert updated_agent.latest_version.name == "Research Coordinator v2"
    assert element(edit_view, "#version-list") |> render() =~ "Version 2"
  end

  test "launches a session inline and streams output without leaving the page", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    configure_runtime_inference!("Inspect the release status", "The release status is green.")

    agent = create_agent!(user)
    environment = create_environment!(user)
    vault = create_vault!(user)

    {:ok, view, _html} = live(conn, ~p"/console/agents/#{agent.id}/edit")

    render_submit(element(view, "#agent-runner-form"), %{
      "runner" => %{
        "environment_id" => environment.id,
        "title" => "Launch Smoke Test",
        "vault_ids" => [vault.id],
        "prompt" => "Inspect the release status"
      }
    })

    assert wait_until(fn -> has_element?(view, "#runner-event-4") end)
    assert element(view, "#runner-notice") |> render() =~ "Streaming inline from session"
    assert element(view, "#runner-events") |> render() =~ "agent.message"
    assert element(view, "#runner-events") |> render() =~ "The release status is green."

    session =
      Session
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
      |> Ash.Query.filter(agent_id == ^agent.id and title == "Launch Smoke Test")
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(:session_vaults)
      |> Ash.read_one!()

    assert session.environment_id == environment.id
    assert Enum.map(session.session_vaults, & &1.vault_id) == [vault.id]
  end

  test "surfaces a clear conflict when the workspace already has an active session", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    agent = create_agent!(user)
    environment = create_environment!(user)
    workspace = create_workspace!(user, agent)
    version = latest_agent_version!(user, agent)

    _session =
      create_session!(user, agent, version, environment, workspace, %{title: "Existing Session"})

    {:ok, view, _html} = live(conn, ~p"/console/agents/#{agent.id}/edit")

    render_submit(element(view, "#agent-runner-form"), %{
      "runner" => %{
        "environment_id" => environment.id,
        "title" => "Blocked Launch",
        "vault_ids" => [],
        "prompt" => "Inspect the workspace"
      }
    })

    assert wait_until(fn -> has_element?(view, "#runner-error") end)
    assert element(view, "#runner-error") |> render() =~ "workspace already has an active session"
  end

  defp builder_params(name) do
    %{
      "name" => name,
      "description" => "Coordinates a console test run",
      "system" => "Stay precise.",
      "metadata_json" => ~s({"team":"platform"}),
      "model" => %{"provider" => "", "id" => "claude-sonnet-4-6", "speed" => "standard"},
      "tools" =>
        indexed_form_list([
          %{
            "type" => "agent_toolset_20260401",
            "default_config_json" => ~s({"permission_policy":"always_ask"}),
            "configs_json" => "{}",
            "mcp_server_name" => "",
            "permission_policy" => "always_ask",
            "name" => "",
            "description" => "",
            "input_schema_json" => ~s({"type":"object","properties":{}})
          }
        ]),
      "mcp_servers" =>
        indexed_form_list([
          %{
            "type" => "url",
            "name" => "docs",
            "url" => "https://example.com/mcp",
            "headers_json" => ~s({"x-scope":"engineering"})
          }
        ]),
      "skills" => %{},
      "callable_agents" => %{}
    }
  end

  defp indexed_form_list(items) do
    items
    |> Enum.with_index()
    |> Map.new(fn {item, index} -> {Integer.to_string(index), item} end)
  end

  defp get_agent_by_name!(user, name) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.load(AgentCatalog.latest_version_load())
    |> Ash.read_one!()
  end

  defp configure_runtime_inference!(expected_prompt, reply_text) do
    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.SessionRuntime,
      anthropic_compatible_provider: :anthropic,
      max_tokens: 1024,
      temperature: 0.2,
      timeout: 30_000,
      req_http_options: [plug: success_anthropic_plug(expected_prompt, reply_text)]
    )
  end

  defp success_anthropic_plug(expected_prompt, reply_text) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      assert get_in(params, ["messages", Access.at(0), "content"]) == expected_prompt or
               get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"]) ==
                 expected_prompt

      response =
        Jason.encode!(%{
          "id" => "msg_console_success",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [%{"type" => "text", "text" => reply_text}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 18}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response)
    end
  end

  defp wait_until(fun, attempts \\ 60)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false
end
