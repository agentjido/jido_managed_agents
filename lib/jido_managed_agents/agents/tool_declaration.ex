defmodule JidoManagedAgents.Agents.ToolDeclaration do
  @moduledoc """
  Normalizes Anthropic-compatible tool declarations into a canonical shape
  persisted on agent versions and consumed directly by the runtime.
  """

  use Ash.Type

  @builtin_toolset_type "agent_toolset_20260401"
  @mcp_toolset_type "mcp_toolset"
  @custom_tool_type "custom"

  @builtin_tool_names ~w(bash read write edit glob grep web_fetch web_search)
  @permission_policies ~w(always_allow always_ask)
  @default_permission_policy "always_ask"

  @builtin_toolset_keys MapSet.new(["type", "default_config", "configs"])
  @mcp_toolset_keys MapSet.new(["type", "mcp_server_name", "permission_policy"])
  @custom_tool_keys MapSet.new([
                      "type",
                      "name",
                      "description",
                      "input_schema",
                      "permission_policy"
                    ])

  @type error_details :: keyword()

  @spec builtin_toolset_type() :: String.t()
  def builtin_toolset_type, do: @builtin_toolset_type

  @spec builtin_tool_names() :: [String.t()]
  def builtin_tool_names, do: @builtin_tool_names

  @spec permission_policies() :: [String.t()]
  def permission_policies, do: @permission_policies

  @spec default_permission_policy() :: String.t()
  def default_permission_policy, do: @default_permission_policy

  @spec normalize(term()) :: {:ok, map()} | {:error, error_details()}
  def normalize(value) when is_map(value) do
    value = stringify(value)

    case Map.get(value, "type") do
      @builtin_toolset_type -> normalize_builtin_toolset(value)
      @mcp_toolset_type -> normalize_mcp_toolset(value)
      @custom_tool_type -> normalize_custom_tool(value)
      nil -> {:error, error(["type"], "is required.")}
      _other -> {:error, error(["type"], "must be one of #{Enum.join(supported_types(), ", ")}.")}
    end
  end

  def normalize(_value), do: {:error, error([], "must be an object.")}

  @spec normalize_many(term()) :: {:ok, [map()]} | {:error, error_details()}
  def normalize_many(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize(value) do
        {:ok, normalized_value} ->
          {:cont, {:ok, [normalized_value | acc]}}

        {:error, details} ->
          {:halt, {:error, Keyword.update(details, :path, [index], &[index | &1])}}
      end
    end)
    |> case do
      {:ok, normalized_values} -> {:ok, Enum.reverse(normalized_values)}
      {:error, details} -> {:error, details}
    end
  end

  def normalize_many(_values), do: {:error, error([], "must be an array of objects.")}

  @spec format_error(String.t(), error_details()) :: String.t()
  def format_error(field, details) when is_binary(field) and is_list(details) do
    path =
      case Keyword.get(details, :path, []) do
        [] -> [field]
        segments -> [field | segments]
      end

    "#{Enum.map_join(path, ".", &to_string/1)} #{Keyword.fetch!(details, :message)}"
  end

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints), do: normalize(value)

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints), do: normalize(value)

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: normalize(value)

  defp normalize_builtin_toolset(value) do
    with :ok <- ensure_allowed_keys(value, @builtin_toolset_keys),
         {:ok, default_config} <- normalize_builtin_config(Map.get(value, "default_config"), true),
         {:ok, configs} <- normalize_builtin_configs(Map.get(value, "configs")) do
      {:ok,
       %{
         "type" => @builtin_toolset_type,
         "default_config" => default_config,
         "configs" => configs
       }}
    end
  end

  defp normalize_mcp_toolset(value) do
    with :ok <- ensure_allowed_keys(value, @mcp_toolset_keys),
         {:ok, mcp_server_name} <-
           required_string(Map.get(value, "mcp_server_name"), ["mcp_server_name"]),
         {:ok, permission_policy} <-
           normalize_permission_policy(
             Map.get(value, "permission_policy"),
             ["permission_policy"],
             default: @default_permission_policy
           ) do
      {:ok,
       %{
         "type" => @mcp_toolset_type,
         "mcp_server_name" => mcp_server_name,
         "permission_policy" => permission_policy
       }}
    end
  end

  defp normalize_custom_tool(value) do
    with :ok <- ensure_allowed_keys(value, @custom_tool_keys),
         {:ok, name} <- required_string(Map.get(value, "name"), ["name"]),
         {:ok, description} <- required_string(Map.get(value, "description"), ["description"]),
         {:ok, input_schema} <- required_map(Map.get(value, "input_schema"), ["input_schema"]),
         {:ok, permission_policy} <-
           normalize_permission_policy(
             Map.get(value, "permission_policy"),
             ["permission_policy"],
             default: @default_permission_policy
           ) do
      {:ok,
       %{
         "type" => @custom_tool_type,
         "name" => name,
         "description" => description,
         "input_schema" => input_schema,
         "permission_policy" => permission_policy
       }}
    end
  end

  defp normalize_builtin_configs(nil), do: {:ok, %{}}

  defp normalize_builtin_configs(configs) when is_map(configs) do
    configs = stringify(configs)

    configs
    |> Enum.reduce_while({:ok, %{}}, fn {tool_name, config}, {:ok, acc} ->
      cond do
        tool_name not in @builtin_tool_names ->
          {:halt, {:error, error(["configs", tool_name], "is not a supported built-in tool.")}}

        not is_map(config) ->
          {:halt, {:error, error(["configs", tool_name], "must be an object.")}}

        true ->
          case normalize_builtin_config(config, false) do
            {:ok, normalized_config} ->
              {:cont, {:ok, Map.put(acc, tool_name, normalized_config)}}

            {:error, details} ->
              {:halt,
               {:error,
                Keyword.update(details, :path, ["configs", tool_name], fn path ->
                  ["configs", tool_name | path]
                end)}}
          end
      end
    end)
  end

  defp normalize_builtin_configs(_configs) do
    {:error, error(["configs"], "must be an object keyed by supported built-in tool names.")}
  end

  defp normalize_builtin_config(nil, true) do
    {:ok, %{"permission_policy" => @default_permission_policy}}
  end

  defp normalize_builtin_config(nil, false), do: {:ok, %{}}

  defp normalize_builtin_config(config, default_permission_policy?) when is_map(config) do
    config = stringify(config)

    with :ok <- validate_boolean(config, "enabled"),
         {:ok, permission_policy} <-
           normalize_permission_policy(
             Map.get(config, "permission_policy"),
             ["permission_policy"],
             default: if(default_permission_policy?, do: @default_permission_policy)
           ) do
      {:ok, maybe_put(config, "permission_policy", permission_policy)}
    end
  end

  defp normalize_builtin_config(_config, _default_permission_policy?) do
    {:error, error(["default_config"], "must be an object.")}
  end

  defp ensure_allowed_keys(value, allowed_keys) do
    case value |> Map.keys() |> Enum.reject(&MapSet.member?(allowed_keys, &1)) |> Enum.sort() do
      [] -> :ok
      [unknown_key | _rest] -> {:error, error([unknown_key], "is not supported.")}
    end
  end

  defp required_string(value, _path) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp required_string(_value, path), do: {:error, error(path, "is required.")}

  defp required_map(value, _path) when is_map(value), do: {:ok, stringify(value)}
  defp required_map(_value, path), do: {:error, error(path, "must be an object.")}

  defp validate_boolean(value, key) do
    case Map.fetch(value, key) do
      :error -> :ok
      {:ok, boolean} when is_boolean(boolean) -> :ok
      {:ok, _other} -> {:error, error([key], "must be a boolean.")}
    end
  end

  defp normalize_permission_policy(nil, _path, opts) do
    {:ok, Keyword.get(opts, :default)}
  end

  defp normalize_permission_policy(value, path, _opts) do
    value =
      case value do
        atom when is_atom(atom) and atom not in [nil, true, false] -> Atom.to_string(atom)
        other -> other
      end

    if value in @permission_policies do
      {:ok, value}
    else
      {:error, error(path, "must be one of #{Enum.join(@permission_policies, " or ")}.")}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error(path, message), do: [path: path, message: message]

  defp supported_types do
    [@builtin_toolset_type, @mcp_toolset_type, @custom_tool_type]
  end

  defp stringify(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), stringify(item)} end)
    |> Map.new()
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value), do: value
end
