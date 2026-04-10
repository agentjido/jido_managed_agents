defmodule JidoManagedAgents.Sessions.RuntimeMCP do
  @moduledoc """
  Runtime MCP integration for session turns.

  Agent definitions declare MCP servers and MCP toolsets, while session vaults
  supply credentials. This module resolves those pieces at turn time and routes
  discovery and invocation through `jido_mcp`.

  The runtime keeps a bounded pool of reusable endpoint slots so concurrent
  sessions can talk to different MCP servers without creating endpoint atoms
  from session data.
  """

  alias Anubis.Client.Base
  alias Jido.MCP
  alias JidoManagedAgents.Sessions.RuntimeMCP.EndpointPool
  alias JidoManagedAgents.Sessions.Session
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @default_protocol_version "2025-03-26"
  @default_request_timeout_ms 30_000

  @type tool_entry :: %{
          required(:tool) => Tool.t(),
          required(:local_name) => String.t(),
          required(:remote_tool_name) => String.t(),
          required(:mcp_server_name) => String.t(),
          required(:mcp_server_url) => String.t(),
          required(:permission_policy) => String.t(),
          optional(:headers) => map()
        }

  @spec discover_tools(Session.t()) :: {:ok, [tool_entry()]} | {:error, map()}
  def discover_tools(%Session{} = session) do
    session
    |> mcp_tool_declarations()
    |> Enum.reduce_while({:ok, []}, fn declaration, {:ok, acc} ->
      with {:ok, server} <- resolve_server(session, declaration),
           {:ok, credential} <- resolve_credential(session, server),
           {:ok, %{data: %{"tools" => tools}}} <-
             with_ready_endpoint(server, credential, fn endpoint_id ->
               safe_mcp_call(fn -> MCP.list_tools(endpoint_id) end)
             end) do
        entries =
          tools
          |> List.wrap()
          |> Enum.map(&build_tool_entry(server, declaration, &1))

        {:cont, {:ok, acc ++ entries}}
      else
        {:ok, %{data: data}} ->
          {:halt,
           {:error,
            discovery_error(
              declaration,
              resolve_server_url(session, declaration),
              "MCP tool discovery returned an invalid payload.",
              %{payload: stringify(data)}
            )}}

        {:error, %{} = error} ->
          if passthrough_discovery_error?(error) do
            {:halt, {:error, error}}
          else
            {:halt,
             {:error,
              discovery_error(
                declaration,
                resolve_server_url(session, declaration),
                extract_error_message(error, "MCP tool discovery failed."),
                %{
                  "mcp_error_type" => Map.get(error, :type) || Map.get(error, "type"),
                  "details" => normalized_error_details(error)
                }
              )}}
          end

        {:error, error} ->
          {:halt,
           {:error,
            discovery_error(
              declaration,
              resolve_server_url(session, declaration),
              "MCP tool discovery failed.",
              %{details: inspect(error)}
            )}}
      end
    end)
  end

  @spec tool_entry([tool_entry()], String.t()) :: tool_entry() | nil
  def tool_entry(entries, local_name) when is_list(entries) and is_binary(local_name) do
    Enum.find(entries, &(&1.local_name == local_name))
  end

  @spec permission_policy(tool_entry()) :: String.t()
  def permission_policy(entry), do: Map.fetch!(entry, :permission_policy)

  @spec execute(Session.t(), map() | ToolCall.t(), tool_entry()) ::
          {:ok, map()} | {:error, map()}
  def execute(%Session{} = session, tool_call, entry) when is_map(entry) do
    %{id: id, name: local_name, arguments: arguments} = ToolCall.from_map(tool_call)
    input = stringify(arguments)

    with {:ok, server} <- server_from_entry(entry),
         {:ok, credential} <- resolve_credential(session, server),
         {:ok, %{data: data}} <-
           with_ready_endpoint(server, credential, fn endpoint_id ->
             safe_mcp_call(fn ->
               MCP.call_tool(endpoint_id, entry.remote_tool_name, arguments)
             end)
           end) do
      {:ok, ok_result(id, local_name, input, entry, data)}
    else
      {:error, %{} = error} ->
        {:error, error_result(id, local_name, input, entry, error)}

      {:error, error} ->
        {:error,
         error_result(
           id,
           local_name,
           input,
           entry,
           %{
             "error_type" => "mcp_tool_error",
             "message" => "MCP tool execution failed.",
             "details" => inspect(error)
           }
         )}
    end
  end

  @spec execute_use_event(Session.t(), map()) :: {:ok, map()} | {:error, map()}
  def execute_use_event(%Session{} = session, payload) when is_map(payload) do
    payload = stringify(payload)

    with tool_use_id when is_binary(tool_use_id) and byte_size(tool_use_id) > 0 <-
           Map.get(payload, "tool_use_id"),
         tool_name when is_binary(tool_name) and byte_size(tool_name) > 0 <-
           Map.get(payload, "tool_name"),
         remote_tool_name when is_binary(remote_tool_name) and byte_size(remote_tool_name) > 0 <-
           Map.get(payload, "remote_tool_name"),
         mcp_server_name when is_binary(mcp_server_name) and byte_size(mcp_server_name) > 0 <-
           Map.get(payload, "mcp_server_name"),
         mcp_server_url when is_binary(mcp_server_url) and byte_size(mcp_server_url) > 0 <-
           Map.get(payload, "mcp_server_url") do
      execute(
        session,
        %{
          "id" => tool_use_id,
          "name" => tool_name,
          "arguments" => Map.get(payload, "input", %{})
        },
        %{
          local_name: tool_name,
          remote_tool_name: remote_tool_name,
          mcp_server_name: mcp_server_name,
          mcp_server_url: mcp_server_url,
          permission_policy: Map.get(payload, "permission_policy", "always_ask"),
          headers: Map.get(payload, "mcp_server_headers", %{})
        }
      )
    else
      _other ->
        {:error,
         %{
           "error_type" => "invalid_mcp_tool_use",
           "message" => "Blocked MCP tool use is missing runtime metadata."
         }}
    end
  end

  defp mcp_tool_declarations(%Session{agent_version: %{tools: tools}}) when is_list(tools) do
    Enum.filter(tools, &(Map.get(&1, "type") == "mcp_toolset"))
  end

  defp mcp_tool_declarations(%Session{}), do: []

  defp resolve_server(%Session{agent_version: %{mcp_servers: servers}}, declaration)
       when is_list(servers) do
    server_name = Map.get(declaration, "mcp_server_name")

    case Enum.find(servers, &(Map.get(stringify(&1), "name") == server_name)) do
      nil ->
        {:error,
         %{
           "error_type" => "mcp_server_not_found",
           "message" => "MCP toolset references an unknown MCP server.",
           "mcp_server_name" => server_name
         }}

      server ->
        server = stringify(server)

        cond do
          Map.get(server, "type") != "url" ->
            {:error,
             %{
               "error_type" => "unsupported_mcp_server",
               "message" => "Only MCP servers with type=url are supported at runtime.",
               "mcp_server_name" => server_name,
               "mcp_server_url" => Map.get(server, "url")
             }}

          not valid_string?(Map.get(server, "url")) ->
            {:error,
             %{
               "error_type" => "invalid_mcp_server",
               "message" => "MCP server declarations must include a non-empty url.",
               "mcp_server_name" => server_name
             }}

          true ->
            {:ok,
             %{
               name: server_name,
               url: Map.get(server, "url"),
               headers: Map.get(server, "headers", %{})
             }}
        end
    end
  end

  defp resolve_server(%Session{} = session, declaration) do
    {:error,
     %{
       "error_type" => "mcp_server_not_found",
       "message" => "MCP toolset references an unknown MCP server.",
       "mcp_server_name" => Map.get(declaration, "mcp_server_name"),
       "mcp_server_url" => resolve_server_url(session, declaration)
     }}
  end

  defp resolve_server_url(%Session{agent_version: %{mcp_servers: servers}}, declaration)
       when is_list(servers) do
    server_name = Map.get(declaration, "mcp_server_name")

    servers
    |> Enum.find(&(Map.get(stringify(&1), "name") == server_name))
    |> case do
      nil -> nil
      server -> Map.get(stringify(server), "url")
    end
  end

  defp resolve_server_url(%Session{}, _declaration), do: nil

  defp resolve_credential(%Session{session_vaults: session_vaults}, %{url: server_url} = server)
       when is_list(session_vaults) do
    session_vaults
    |> Enum.sort_by(& &1.position)
    |> Enum.find_value(fn session_vault ->
      credentials =
        session_vault
        |> Map.get(:vault)
        |> Map.get(:credentials, [])
        |> List.wrap()
        |> Enum.sort_by(&{&1.created_at || ~U[1970-01-01 00:00:00Z], &1.id})

      case Enum.find(credentials, &(&1.mcp_server_url == server_url)) do
        nil -> nil
        credential -> {:ok, credential}
      end
    end)
    |> case do
      nil ->
        {:error,
         %{
           "error_type" => "mcp_credentials_not_found",
           "message" => "No session vault credential matches the MCP server URL.",
           "mcp_server_name" => server.name,
           "mcp_server_url" => server.url
         }}

      result ->
        result
    end
  end

  defp resolve_credential(%Session{}, %{name: name, url: url}) do
    {:error,
     %{
       "error_type" => "mcp_credentials_not_found",
       "message" => "No session vault credential matches the MCP server URL.",
       "mcp_server_name" => name,
       "mcp_server_url" => url
     }}
  end

  defp build_tool_entry(server, declaration, remote_tool) do
    remote_tool = stringify(remote_tool)
    remote_name = Map.get(remote_tool, "name", "tool")
    local_name = local_tool_name(server.name, remote_name)

    %{
      tool:
        Tool.new!(
          name: local_name,
          description:
            Map.get(
              remote_tool,
              "description",
              "MCP proxy tool #{remote_name} exposed by #{server.name}."
            ),
          parameter_schema: Map.get(remote_tool, "inputSchema", default_input_schema()),
          callback: {JidoManagedAgents.Sessions.RuntimeTools, :noop_tool_callback}
        ),
      local_name: local_name,
      remote_tool_name: remote_name,
      mcp_server_name: server.name,
      mcp_server_url: server.url,
      permission_policy: Map.get(declaration, "permission_policy", "always_ask"),
      headers: stringify(Map.get(server, :headers, %{}))
    }
  end

  defp local_tool_name(server_name, remote_tool_name) do
    "mcp_#{sanitize(server_name)}_#{sanitize(remote_tool_name)}"
  end

  defp sanitize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "tool"
      normalized -> normalized
    end
  end

  defp server_from_entry(entry) do
    {:ok,
     %{
       name: Map.fetch!(entry, :mcp_server_name),
       url: Map.fetch!(entry, :mcp_server_url),
       headers: Map.get(entry, :headers, %{})
     }}
  end

  defp ok_result(id, tool_name, input, entry, result) do
    %{
      "tool_use_id" => id,
      "tool_name" => tool_name,
      "input" => input,
      "ok" => true,
      "result" => stringify(result),
      "remote_tool_name" => entry.remote_tool_name,
      "mcp_server_name" => entry.mcp_server_name,
      "mcp_server_url" => entry.mcp_server_url
    }
  end

  defp error_result(id, tool_name, input, entry, error) do
    %{
      "tool_use_id" => id,
      "tool_name" => tool_name,
      "input" => input,
      "ok" => false,
      "error" =>
        error
        |> normalize_tool_error(entry)
        |> stringify(),
      "remote_tool_name" => entry.remote_tool_name,
      "mcp_server_name" => entry.mcp_server_name,
      "mcp_server_url" => entry.mcp_server_url
    }
  end

  defp normalize_tool_error(%{"error_type" => _} = error, _entry), do: error

  defp normalize_tool_error(error, entry) do
    %{
      "error_type" => "mcp_tool_error",
      "message" => extract_error_message(error, "MCP tool execution failed."),
      "mcp_server_name" => entry.mcp_server_name,
      "mcp_server_url" => entry.mcp_server_url,
      "remote_tool_name" => entry.remote_tool_name,
      "details" => normalized_error_details(error)
    }
  end

  defp discovery_error(declaration, server_url, message, extra) do
    %{
      "error_type" => "mcp_tool_discovery_error",
      "message" => message,
      "mcp_server_name" => Map.get(declaration, "mcp_server_name"),
      "mcp_server_url" => server_url
    }
    |> Map.merge(stringify(extra))
  end

  defp extract_error_message(%{message: message}, _default) when is_binary(message), do: message

  defp extract_error_message(%{"message" => message}, _default) when is_binary(message),
    do: message

  defp extract_error_message({:shutdown, reason}, default),
    do: extract_error_message(reason, default)

  defp extract_error_message({reason, _details}, default),
    do: extract_error_message(reason, default)

  defp extract_error_message(_error, default), do: default

  defp normalized_error_details(error) when is_map(error), do: stringify(error)
  defp normalized_error_details(error), do: %{"details" => inspect(error)}

  defp with_ready_endpoint(server, credential, fun) when is_function(fun, 1) do
    with :ok <- ensure_jido_mcp_started(),
         {:ok, endpoint_id} <-
           EndpointPool.checkout(build_endpoint(server, credential), @default_request_timeout_ms) do
      try do
        with {:ok, _endpoint, ref} <- safe_client_refresh(endpoint_id),
             :ok <- await_client_initialization(ref.client) do
          fun.(endpoint_id)
        end
      after
        EndpointPool.release(endpoint_id)
      end
    end
  end

  defp ensure_jido_mcp_started do
    case Application.ensure_all_started(:jido_mcp) do
      {:ok, _started} ->
        :ok

      {:error, {:already_started, :jido_mcp}} ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           "error_type" => "mcp_runtime_unavailable",
           "message" => "The MCP runtime could not be started.",
           "details" => inspect(reason)
         }}
    end
  end

  defp safe_client_refresh(endpoint_id) do
    try do
      Jido.MCP.ClientPool.refresh(endpoint_id)
    catch
      :exit, reason ->
        {:error, normalize_client_exit(reason, "MCP client refresh failed.")}
    end
  end

  defp await_client_initialization(client_name, timeout_ms \\ @default_request_timeout_ms) do
    case resolve_process(client_name) do
      pid when is_pid(pid) ->
        monitor_ref = Process.monitor(pid)

        try do
          deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
          do_await_client_initialization(client_name, pid, monitor_ref, deadline_ms)
        after
          Process.demonitor(monitor_ref, [:flush])
        end

      _other ->
        {:error,
         %{
           type: :transport,
           message: "MCP client failed to start.",
           details: "client process was unavailable after refresh"
         }}
    end
  end

  defp do_await_client_initialization(client_name, pid, monitor_ref, deadline_ms) do
    case safe_get_server_capabilities(client_name) do
      {:ok, capabilities} when is_map(capabilities) ->
        :ok

      {:ok, nil} ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        cond do
          remaining_ms <= 0 ->
            {:error,
             %{
               type: :transport,
               message: "MCP client initialization timed out.",
               details: "server capabilities were not reported before the request timeout elapsed"
             }}

          not Process.alive?(pid) ->
            {:error, normalize_client_exit(:shutdown, "MCP client initialization failed.")}

          true ->
            receive do
              {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
                {:error, normalize_client_exit(reason, "MCP client initialization failed.")}
            after
              min(20, remaining_ms) ->
                do_await_client_initialization(client_name, pid, monitor_ref, deadline_ms)
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp safe_get_server_capabilities(client_name) do
    try do
      {:ok, Base.get_server_capabilities(client_name)}
    catch
      :exit, reason ->
        {:error, normalize_client_exit(reason, "MCP client initialization failed.")}
    end
  end

  defp safe_mcp_call(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      :exit, reason ->
        {:error, normalize_client_exit(reason, "MCP request failed because the client exited.")}
    end
  end

  defp normalize_client_exit(reason, message) do
    %{
      type: :transport,
      message: extract_error_message(reason, message),
      details: inspect(reason)
    }
  end

  defp resolve_process(name) when is_tuple(name), do: GenServer.whereis(name)
  defp resolve_process(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_process(name) when is_pid(name), do: name
  defp resolve_process(_name), do: nil

  defp passthrough_discovery_error?(%{"error_type" => error_type}) do
    error_type in [
      "mcp_server_not_found",
      "unsupported_mcp_server",
      "invalid_mcp_server",
      "mcp_credentials_not_found",
      "mcp_runtime_unavailable"
    ]
  end

  defp passthrough_discovery_error?(_error), do: false

  defp build_endpoint(server, credential) do
    {base_url, mcp_path} = split_server_url(server.url)

    %{
      transport:
        {:streamable_http,
         [
           base_url: base_url,
           mcp_path: mcp_path,
           headers: build_headers(server, credential)
         ]},
      client_info: %{
        name: "jido_managed_agents",
        version: app_version()
      },
      protocol_version: @default_protocol_version,
      capabilities: %{},
      timeouts: %{request_ms: @default_request_timeout_ms}
    }
  end

  defp split_server_url(url) do
    uri = URI.parse(url)

    base_url =
      %URI{uri | path: nil, query: nil, fragment: nil}
      |> URI.to_string()
      |> String.trim_trailing("/")

    mcp_path =
      case uri.path do
        path when is_binary(path) and path != "" -> path
        _other -> "/mcp"
      end

    {base_url, mcp_path}
  end

  defp build_headers(server, credential) do
    server_headers = stringify(Map.get(server, :headers, %{}))

    case credential.access_token do
      token when is_binary(token) and token != "" ->
        Map.put(server_headers, "Authorization", "Bearer #{token}")

      _other ->
        server_headers
    end
  end

  defp app_version do
    case Application.spec(:jido_managed_agents, :vsn) do
      nil -> "0.1.0"
      version -> List.to_string(version)
    end
  end

  defp default_input_schema do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  defp valid_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp stringify(%_{} = struct), do: struct |> Map.from_struct() |> stringify()

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&stringify/1)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
