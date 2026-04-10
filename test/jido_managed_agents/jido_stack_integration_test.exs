defmodule JidoManagedAgents.JidoStackIntegrationTest do
  use ExUnit.Case, async: false

  setup_all do
    port = free_port()
    previous_endpoints = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      managed_agents: %{
        transport: {:streamable_http, [base_url: "http://127.0.0.1:#{port}"]},
        client_info: %{name: "jido_managed_agents", version: "0.1.0"},
        protocol_version: "2025-03-26",
        capabilities: %{},
        timeouts: %{request_ms: 30_000}
      }
    })

    restart_mcp_application!()

    start_supervised!(
      {Bandit,
       plug: JidoManagedAgentsWeb.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )

    assert {:ok, _endpoint} = Jido.MCP.Config.fetch_endpoint(:managed_agents)
    wait_for_mcp_client!(:managed_agents)

    on_exit(fn ->
      if is_nil(previous_endpoints) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous_endpoints)
      end

      restart_mcp_application!()
    end)

    :ok
  end

  test "starts a Jido.AI agent under the project Jido runtime" do
    {agent_id, pid} = start_math_agent()

    assert is_pid(pid)
    assert JidoManagedAgents.Jido.whereis(agent_id) == pid

    assert {:ok, tools} = Jido.AI.list_tools(pid)
    assert Enum.any?(tools, &(&1.name() == "add_numbers"))
  end

  test "exposes the local MCP server over Phoenix" do
    assert {:ok, %{data: %{"tools" => tools}}} = Jido.MCP.list_tools(:managed_agents)
    assert Enum.any?(tools, &(&1["name"] == "add_numbers"))

    assert {:ok, %{data: data}} =
             Jido.MCP.call_tool(:managed_agents, "add_numbers", %{"a" => 19, "b" => 23})

    assert get_in(data, ["structuredContent", "sum"]) == 42
  end

  test "syncs MCP tools into a running Jido.AI agent" do
    {_agent_id, pid} = start_math_agent()

    assert {:ok, result} =
             Jido.MCP.JidoAI.Actions.SyncToolsToAgent.run(
               %{
                 endpoint_id: :managed_agents,
                 agent_server: pid,
                 prefix: "managed_agents_"
               },
               %{}
             )

    assert result.registered_count == 1
    assert "managed_agents_add_numbers" in result.registered_tools

    assert {:ok, tools} = Jido.AI.list_tools(pid)
    assert Enum.any?(tools, &(&1.name() == "managed_agents_add_numbers"))
  end

  defp start_math_agent do
    agent_id = "math-agent-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      JidoManagedAgents.Jido.start_agent(JidoManagedAgents.Agents.MathAgent, id: agent_id)

    on_exit(fn ->
      _ = JidoManagedAgents.Jido.stop_agent(agent_id)
    end)

    {agent_id, pid}
  end

  defp wait_for_mcp_client!(endpoint_id, attempts \\ 50)

  defp wait_for_mcp_client!(_endpoint_id, 0) do
    flunk("timed out waiting for MCP client initialization")
  end

  defp wait_for_mcp_client!(endpoint_id, attempts) do
    {:ok, _endpoint, ref} = Jido.MCP.ClientPool.ensure_client(endpoint_id)

    case Anubis.Client.Base.get_server_capabilities(ref.client) do
      capabilities when is_map(capabilities) ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_mcp_client!(endpoint_id, attempts - 1)
    end
  end

  defp restart_mcp_application! do
    if Application.started_applications() |> Enum.any?(fn {app, _, _} -> app == :jido_mcp end) do
      :ok = Application.stop(:jido_mcp)
    end

    {:ok, _started} = Application.ensure_all_started(:jido_mcp)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
