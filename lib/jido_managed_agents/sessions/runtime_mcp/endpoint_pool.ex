defmodule JidoManagedAgents.Sessions.RuntimeMCP.EndpointPool do
  @moduledoc false

  use GenServer

  @slot_count 8
  @endpoint_ids Enum.map(1..@slot_count, &:"managed_agents_runtime_mcp_#{&1}")
  @checkout_retry_ms 25

  @type endpoint_id :: atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec checkout(map(), pos_integer()) :: {:ok, endpoint_id()} | {:error, map()}
  def checkout(endpoint, timeout_ms)
      when is_map(endpoint) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_checkout(endpoint, deadline_ms)
  end

  @spec release(endpoint_id()) :: :ok
  def release(endpoint_id) when is_atom(endpoint_id) do
    GenServer.cast(__MODULE__, {:release, endpoint_id})
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       available: @endpoint_ids,
       endpoint_refs: %{},
       monitor_refs: %{}
     }}
  end

  @impl true
  def handle_call({:checkout, owner, endpoint}, _from, %{available: [endpoint_id | rest]} = state) do
    case configure_runtime_endpoint(endpoint_id, endpoint) do
      :ok ->
        monitor_ref = Process.monitor(owner)

        next_state = %{
          state
          | available: rest,
            endpoint_refs: Map.put(state.endpoint_refs, endpoint_id, monitor_ref),
            monitor_refs: Map.put(state.monitor_refs, monitor_ref, endpoint_id)
        }

        {:reply, {:ok, endpoint_id}, next_state}

      {:error, reason} ->
        {:reply, {:error, normalize_pool_error(reason)}, state}
    end
  end

  def handle_call({:checkout, _owner, _endpoint}, _from, state) do
    {:reply, :busy, state}
  end

  @impl true
  def handle_cast({:release, endpoint_id}, state) do
    {:noreply, release_endpoint(state, endpoint_id)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_refs, monitor_ref) do
      {nil, _monitor_refs} ->
        {:noreply, state}

      {endpoint_id, monitor_refs} ->
        next_state =
          state
          |> Map.put(:monitor_refs, monitor_refs)
          |> Map.update!(:endpoint_refs, &Map.delete(&1, endpoint_id))
          |> Map.update!(:available, fn available -> available ++ [endpoint_id] end)

        {:noreply, next_state}
    end
  end

  defp do_checkout(endpoint, deadline_ms) do
    case GenServer.call(__MODULE__, {:checkout, self(), endpoint}) do
      {:ok, endpoint_id} ->
        {:ok, endpoint_id}

      :busy ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error,
           %{
             "error_type" => "mcp_runtime_busy",
             "message" =>
               "No MCP runtime endpoint slots were available before the request timed out."
           }}
        else
          Process.sleep(min(@checkout_retry_ms, remaining_ms))
          do_checkout(endpoint, deadline_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_endpoint(state, endpoint_id) do
    case Map.pop(state.endpoint_refs, endpoint_id) do
      {nil, _endpoint_refs} ->
        state

      {monitor_ref, endpoint_refs} ->
        Process.demonitor(monitor_ref, [:flush])

        state
        |> Map.put(:endpoint_refs, endpoint_refs)
        |> Map.update!(:monitor_refs, &Map.delete(&1, monitor_ref))
        |> Map.update!(:available, fn available -> available ++ [endpoint_id] end)
    end
  end

  defp configure_runtime_endpoint(endpoint_id, endpoint) do
    endpoints =
      :jido_mcp
      |> Application.get_env(:endpoints, %{})
      |> Map.new()
      |> ensure_runtime_slots()
      |> Map.put(endpoint_id, endpoint_with_slot_name(endpoint_id, endpoint))

    Application.put_env(:jido_mcp, :endpoints, endpoints)
    sync_client_pool_endpoints()
  end

  defp ensure_runtime_slots(endpoints) do
    Enum.reduce(@endpoint_ids, endpoints, fn endpoint_id, acc ->
      Map.put_new(acc, endpoint_id, placeholder_endpoint())
    end)
  end

  defp placeholder_endpoint do
    %{
      transport:
        {:streamable_http, [base_url: "http://127.0.0.1", mcp_path: "/mcp", headers: %{}]},
      client_info: %{name: "jido_managed_agents_runtime_slot", version: "0.1.0"},
      protocol_version: "2025-03-26",
      capabilities: %{},
      timeouts: %{request_ms: 30_000}
    }
  end

  defp endpoint_with_slot_name(endpoint_id, endpoint) do
    client_info =
      endpoint
      |> Map.get(:client_info, %{})
      |> Map.new()
      |> Map.put(:name, "jido_managed_agents_#{endpoint_id}")

    Map.put(endpoint, :client_info, client_info)
  end

  defp sync_client_pool_endpoints do
    if Process.whereis(Jido.MCP.ClientPool) do
      :sys.replace_state(Jido.MCP.ClientPool, fn state ->
        %{state | endpoints: Jido.MCP.Config.endpoints()}
      end)
    end

    :ok
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_pool_error(%{} = error), do: error

  defp normalize_pool_error(error),
    do: %{"error_type" => "mcp_runtime_unavailable", "message" => inspect(error)}
end
