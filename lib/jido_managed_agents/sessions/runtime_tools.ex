defmodule JidoManagedAgents.Sessions.RuntimeTools do
  @moduledoc """
  Built-in workspace and filesystem tools used by the session runtime.

  The module keeps built-in tool configuration, request schemas, and execution
  in one place so the runtime can stay focused on turn orchestration.
  """

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Agents.ToolDeclaration
  alias JidoManagedAgents.Sessions.RuntimeWeb
  alias JidoManagedAgents.Sessions.RuntimeWorkspace
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @builtin_tool_names ~w(bash read write edit glob grep web_fetch web_search)
  @filesystem_tool_names ~w(read write edit glob grep)
  @default_bash_policy %{
    "timeout_ms" => 5_000,
    "max_output_bytes" => 65_536,
    "failure_exit_status" => 1,
    "timeout_exit_status" => 124,
    "cancelled_exit_status" => 130,
    "crashed_exit_status" => 137
  }
  @default_runtime_config %{
    web_fetch_max_chars: RuntimeWeb.default_fetch_max_chars(),
    web_fetch_req_options: [],
    web_search_adapter: JidoManagedAgents.Sessions.RuntimeWeb.DuckDuckGoAdapter,
    web_search_adapter_options: [],
    web_search_limit: RuntimeWeb.default_search_limit(),
    web_search_req_options: []
  }
  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map()
        }

  @type tool_result :: map()

  @spec filesystem_tool_names() :: [String.t()]
  def filesystem_tool_names, do: @filesystem_tool_names

  @spec builtin_tool_names() :: [String.t()]
  def builtin_tool_names, do: @builtin_tool_names

  @spec bash_policy() :: map()
  def bash_policy, do: bash_policy(%{})

  @spec bash_policy(map()) :: map()
  def bash_policy(overrides) when is_map(overrides) do
    @default_bash_policy
    |> Map.merge(stringify(overrides))
    |> Map.update!(
      "timeout_ms",
      &normalize_positive_integer(&1, @default_bash_policy["timeout_ms"])
    )
    |> Map.update!(
      "max_output_bytes",
      &normalize_positive_integer(&1, @default_bash_policy["max_output_bytes"])
    )
    |> Map.update!(
      "failure_exit_status",
      &normalize_exit_status(&1, @default_bash_policy["failure_exit_status"])
    )
    |> Map.update!(
      "timeout_exit_status",
      &normalize_exit_status(&1, @default_bash_policy["timeout_exit_status"])
    )
    |> Map.update!(
      "cancelled_exit_status",
      &normalize_exit_status(&1, @default_bash_policy["cancelled_exit_status"])
    )
    |> Map.update!(
      "crashed_exit_status",
      &normalize_exit_status(&1, @default_bash_policy["crashed_exit_status"])
    )
  end

  @spec enabled_filesystem_tools(AgentVersion.t() | nil) :: %{String.t() => map()}
  def enabled_filesystem_tools(agent_version) do
    agent_version
    |> enabled_builtin_tools()
    |> Map.take(@filesystem_tool_names)
  end

  @spec enabled_builtin_tools(AgentVersion.t() | nil) :: %{String.t() => map()}
  def enabled_builtin_tools(nil), do: %{}

  def enabled_builtin_tools(%AgentVersion{tools: tools}) when is_list(tools) do
    default_enabled = %{"enabled" => true}

    tools
    |> Enum.filter(&(Map.get(&1, "type") == ToolDeclaration.builtin_toolset_type()))
    |> Enum.reduce(%{}, fn declaration, acc ->
      default_config =
        default_enabled
        |> Map.merge(Map.get(declaration, "default_config", %{}))

      Enum.reduce(@builtin_tool_names, acc, fn tool_name, tool_acc ->
        config =
          default_config
          |> Map.merge(Map.get(declaration, "configs", %{}) |> Map.get(tool_name, %{}))

        if Map.get(config, "enabled", true) do
          Map.put(tool_acc, tool_name, config)
        else
          Map.delete(tool_acc, tool_name)
        end
      end)
    end)
  end

  def enabled_builtin_tools(%AgentVersion{}), do: %{}

  @spec enabled_custom_tools(AgentVersion.t() | nil) :: %{String.t() => map()}
  def enabled_custom_tools(nil), do: %{}

  def enabled_custom_tools(%AgentVersion{tools: tools}) when is_list(tools) do
    tools
    |> Enum.filter(&(Map.get(&1, "type") == "custom"))
    |> Map.new(fn declaration -> {Map.fetch!(declaration, "name"), declaration} end)
  end

  def enabled_custom_tools(%AgentVersion{}), do: %{}

  @spec tool_definitions(AgentVersion.t() | nil) :: [Tool.t()]
  def tool_definitions(agent_version) do
    builtin_tools =
      agent_version
      |> enabled_builtin_tools()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&tool_definition/1)

    custom_tools =
      agent_version
      |> enabled_custom_tools()
      |> Map.values()
      |> Enum.sort_by(&Map.fetch!(&1, "name"))
      |> Enum.map(&custom_tool_definition/1)

    builtin_tools ++ custom_tools
  end

  @spec permission_policy(AgentVersion.t() | nil, String.t()) :: String.t()
  def permission_policy(agent_version, tool_name) when is_binary(tool_name) do
    cond do
      Map.has_key?(enabled_builtin_tools(agent_version), tool_name) ->
        agent_version
        |> enabled_builtin_tools()
        |> Map.get(tool_name, %{})
        |> Map.get("permission_policy", ToolDeclaration.default_permission_policy())

      Map.has_key?(enabled_custom_tools(agent_version), tool_name) ->
        agent_version
        |> enabled_custom_tools()
        |> Map.get(tool_name, %{})
        |> Map.get("permission_policy", ToolDeclaration.default_permission_policy())

      true ->
        ToolDeclaration.default_permission_policy()
    end
  end

  @spec execute(RuntimeWorkspace.t(), map() | ToolCall.t()) ::
          {:ok, tool_result(), RuntimeWorkspace.t()}
          | {:error, tool_result(), RuntimeWorkspace.t()}
  def execute(%RuntimeWorkspace{} = runtime_workspace, tool_call) do
    execute(runtime_workspace, tool_call, [])
  end

  @spec execute(RuntimeWorkspace.t(), map() | ToolCall.t(), keyword()) ::
          {:ok, tool_result(), RuntimeWorkspace.t()}
          | {:error, tool_result(), RuntimeWorkspace.t()}
  def execute(%RuntimeWorkspace{} = runtime_workspace, tool_call, opts) when is_list(opts) do
    %{id: id, name: name, arguments: arguments} = ToolCall.from_map(tool_call)
    input = stringify(arguments)

    try do
      do_execute(runtime_workspace, id, name, input, opts)
    rescue
      error ->
        {:error,
         error_result(id, name, input, %{
           "error_type" => "tool_execution_error",
           "message" => Exception.message(error)
         }), runtime_workspace}
    catch
      kind, reason ->
        {:error,
         error_result(id, name, input, %{
           "error_type" => "tool_execution_error",
           "message" => "#{kind}: #{inspect(reason)}"
         }), runtime_workspace}
    end
  end

  @spec tool_result_content(tool_result()) :: String.t()
  def tool_result_content(%{"ok" => true, "result" => result}) do
    Jason.encode!(%{"ok" => true, "result" => result})
  end

  def tool_result_content(%{"ok" => false, "error" => error}) do
    Jason.encode!(%{"ok" => false, "error" => error})
  end

  @spec noop_tool_callback(map()) :: {:ok, map()}
  def noop_tool_callback(_args), do: {:ok, %{}}

  defp do_execute(runtime_workspace, id, "bash", %{"command" => command} = input, opts)
       when is_binary(command) do
    execute_bash(runtime_workspace, id, input, opts)
  end

  defp do_execute(runtime_workspace, id, "read", %{"path" => path} = input, _opts)
       when is_binary(path) do
    case RuntimeWorkspace.read(runtime_workspace, path) do
      {:ok, content} ->
        {:ok, ok_result(id, "read", input, %{"path" => path, "content" => content}),
         runtime_workspace}

      {:error, reason} ->
        {:error, error_result(id, "read", input, normalize_error(reason)), runtime_workspace}
    end
  end

  defp do_execute(
         runtime_workspace,
         id,
         "write",
         %{"path" => path, "content" => content} = input,
         _opts
       )
       when is_binary(path) and is_binary(content) do
    case ensure_parent_directory(runtime_workspace, path) do
      {:ok, workspace_with_parent} ->
        case RuntimeWorkspace.write(workspace_with_parent, path, content) do
          {:ok, updated_workspace} ->
            {:ok,
             ok_result(id, "write", input, %{
               "path" => path,
               "bytes_written" => byte_size(content)
             }), updated_workspace}

          {:error, reason} ->
            {:error, error_result(id, "write", input, normalize_error(reason)),
             workspace_with_parent}
        end

      {:error, reason} ->
        {:error, error_result(id, "write", input, normalize_error(reason)), runtime_workspace}
    end
  end

  defp do_execute(
         runtime_workspace,
         id,
         "edit",
         %{"path" => path, "old_text" => old_text, "new_text" => new_text} = input,
         _opts
       )
       when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
    replace_all? = Map.get(input, "replace_all", false)

    case RuntimeWorkspace.edit(
           runtime_workspace,
           path,
           old_text,
           new_text,
           replace_all: replace_all?
         ) do
      {:ok, result, updated_workspace} ->
        {:ok, ok_result(id, "edit", input, result), updated_workspace}

      {:error, reason} ->
        {:error, error_result(id, "edit", input, normalize_error(reason)), runtime_workspace}
    end
  end

  defp do_execute(runtime_workspace, id, "glob", %{"pattern" => pattern} = input, _opts)
       when is_binary(pattern) do
    case RuntimeWorkspace.glob(runtime_workspace, pattern) do
      {:ok, matches} ->
        {:ok, ok_result(id, "glob", input, %{"pattern" => pattern, "matches" => matches}),
         runtime_workspace}

      {:error, reason} ->
        {:error, error_result(id, "glob", input, normalize_error(reason)), runtime_workspace}
    end
  end

  defp do_execute(runtime_workspace, id, "grep", %{"pattern" => pattern} = input, _opts)
       when is_binary(pattern) do
    opts =
      []
      |> maybe_put_opt(:path, Map.get(input, "path"))
      |> maybe_put_opt(:include, Map.get(input, "include"))

    case RuntimeWorkspace.grep(runtime_workspace, pattern, opts) do
      {:ok, matches} ->
        {:ok, ok_result(id, "grep", input, %{"pattern" => pattern, "matches" => matches}),
         runtime_workspace}

      {:error, reason} ->
        {:error, error_result(id, "grep", input, normalize_error(reason)), runtime_workspace}
    end
  end

  defp do_execute(runtime_workspace, id, "web_fetch", %{"url" => url} = input, opts)
       when is_binary(url) do
    case execute_web_fetch(url, opts) do
      {:ok, result} ->
        {:ok, ok_result(id, "web_fetch", input, result), runtime_workspace}

      {:error, error} ->
        {:error, error_result(id, "web_fetch", input, error), runtime_workspace}
    end
  end

  defp do_execute(runtime_workspace, id, "web_search", %{"query" => query} = input, opts)
       when is_binary(query) do
    case execute_web_search(query, input, opts) do
      {:ok, result} ->
        {:ok, ok_result(id, "web_search", input, result), runtime_workspace}

      {:error, error} ->
        {:error, error_result(id, "web_search", input, error), runtime_workspace}
    end
  end

  defp do_execute(runtime_workspace, id, name, input, _opts) when name in @builtin_tool_names do
    {:error,
     error_result(id, name, input, %{
       "error_type" => "invalid_input",
       "message" => "Tool input was missing required fields."
     }), runtime_workspace}
  end

  defp do_execute(runtime_workspace, id, name, input, _opts) do
    {:error,
     error_result(id, name, input, %{
       "error_type" => "unsupported_tool",
       "message" => "Unsupported built-in tool #{name}."
     }), runtime_workspace}
  end

  defp execute_bash(runtime_workspace, id, %{"command" => command} = input, opts) do
    policy = bash_policy(Keyword.get(opts, :bash_policy, %{}))

    case RuntimeWorkspace.run_captured(
           runtime_workspace,
           command,
           timeout: policy["timeout_ms"],
           execution_context: %{
             max_runtime_ms: policy["timeout_ms"],
             max_output_bytes: policy["max_output_bytes"]
           }
         ) do
      {:ok, %{output: output}, updated_workspace} ->
        {:ok,
         ok_result(id, "bash", input, %{
           "output" => output,
           "exit_status" => 0
         }), updated_workspace}

      {:error, %{output: output, shell_error: shell_error}, updated_workspace} ->
        exit_status = bash_exit_status(shell_error, policy)

        {:error,
         error_result(id, "bash", input, %{
           "error_type" => bash_error_type(shell_error),
           "message" => bash_error_message(shell_error, exit_status),
           "output" => output,
           "exit_status" => exit_status
         }), updated_workspace}
    end
  end

  defp execute_web_fetch(url, opts) do
    config = runtime_config(opts)

    RuntimeWeb.fetch(
      url,
      max_chars: config.web_fetch_max_chars,
      req_options: config.web_fetch_req_options
    )
  end

  defp execute_web_search(query, input, opts) do
    config = runtime_config(opts)

    RuntimeWeb.search(
      query,
      limit: normalize_positive_integer(Map.get(input, "max_results"), config.web_search_limit),
      adapter: config.web_search_adapter,
      adapter_options:
        merge_search_adapter_options(
          config.web_search_adapter_options,
          config.web_search_req_options
        )
    )
  end

  defp ok_result(id, name, input, result) do
    %{
      "tool_use_id" => id,
      "tool_name" => name,
      "input" => input,
      "ok" => true,
      "result" => stringify(result)
    }
  end

  defp error_result(id, name, input, error) do
    %{
      "tool_use_id" => id,
      "tool_name" => name,
      "input" => input,
      "ok" => false,
      "error" => stringify(error)
    }
  end

  defp ensure_parent_directory(runtime_workspace, path) do
    case parent_directory(path) do
      "/" ->
        {:ok, runtime_workspace}

      parent ->
        RuntimeWorkspace.mkdir(runtime_workspace, parent)
    end
  end

  defp parent_directory(path) do
    path
    |> Path.dirname()
    |> case do
      "." -> "/"
      parent -> parent
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp merge_search_adapter_options(adapter_options, []), do: adapter_options

  defp merge_search_adapter_options(adapter_options, req_options) when is_list(req_options) do
    Keyword.put(adapter_options, :req_options, req_options)
  end

  defp normalize_error({:invalid_edit, message}) when is_binary(message) do
    %{"error_type" => "invalid_edit", "message" => message}
  end

  defp normalize_error({:invalid_glob, message}) when is_binary(message) do
    %{"error_type" => "invalid_glob", "message" => message}
  end

  defp normalize_error({:invalid_grep, message}) when is_binary(message) do
    %{"error_type" => "invalid_grep", "message" => message}
  end

  defp normalize_error({:unsupported_workspace_backend, backend}) do
    %{
      "error_type" => "unsupported_workspace_backend",
      "message" => "Unsupported workspace backend #{backend}."
    }
  end

  defp normalize_error(reason) when is_atom(reason) do
    %{"error_type" => Atom.to_string(reason), "message" => Atom.to_string(reason)}
  end

  defp normalize_error(%{message: message}) when is_binary(message) and message != "" do
    %{"error_type" => "tool_error", "message" => message}
  end

  defp normalize_error(reason) do
    %{"error_type" => "tool_error", "message" => inspect(reason)}
  end

  defp tool_definition("read") do
    Tool.new!(
      name: "read",
      description: "Read text content from a file in the attached workspace.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute workspace path to read."}
        },
        "required" => ["path"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("bash") do
    Tool.new!(
      name: "bash",
      description: "Run a bounded shell command inside the attached workspace.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute within the workspace session."
          }
        },
        "required" => ["command"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("write") do
    Tool.new!(
      name: "write",
      description: "Write text content to a file in the attached workspace.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute workspace path to write."},
          "content" => %{"type" => "string", "description" => "Full file contents."}
        },
        "required" => ["path", "content"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("edit") do
    Tool.new!(
      name: "edit",
      description: "Replace text in a workspace file using an exact string match.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute workspace path to edit."},
          "old_text" => %{"type" => "string", "description" => "Exact text to replace."},
          "new_text" => %{"type" => "string", "description" => "Replacement text."},
          "replace_all" => %{
            "type" => "boolean",
            "description" => "When true, replace every exact match."
          }
        },
        "required" => ["path", "old_text", "new_text"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("glob") do
    Tool.new!(
      name: "glob",
      description: "Match workspace paths using glob patterns such as **/*.ex.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Glob pattern to evaluate."}
        },
        "required" => ["pattern"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("grep") do
    Tool.new!(
      name: "grep",
      description: "Search workspace files with a regular expression.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Regular expression to search for."},
          "path" => %{
            "type" => "string",
            "description" => "Optional root file or directory path to search within."
          },
          "include" => %{
            "type" => "string",
            "description" => "Optional glob filter applied to candidate file paths."
          }
        },
        "required" => ["pattern"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("web_fetch") do
    Tool.new!(
      name: "web_fetch",
      description: "Fetch a web page and return compact text or metadata for model use.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string", "description" => "Absolute http or https URL to fetch."}
        },
        "required" => ["url"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp tool_definition("web_search") do
    Tool.new!(
      name: "web_search",
      description: "Search the web and return a compact list of normalized results.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query to submit."},
          "max_results" => %{
            "type" => "integer",
            "description" => "Optional maximum number of results to return."
          }
        },
        "required" => ["query"]
      },
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp custom_tool_definition(%{
         "name" => name,
         "description" => description,
         "input_schema" => input_schema
       }) do
    Tool.new!(
      name: name,
      description: description,
      parameter_schema: input_schema,
      callback: {__MODULE__, :noop_tool_callback}
    )
  end

  defp runtime_config(overrides) do
    configured =
      Application.get_env(:jido_managed_agents, __MODULE__, [])
      |> Map.new()

    overrides = Map.new(overrides)

    Map.merge(@default_runtime_config, configured, fn
      :web_fetch_req_options, _default, value when is_list(value) -> value
      :web_search_adapter_options, _default, value when is_list(value) -> value
      :web_search_req_options, _default, value when is_list(value) -> value
      _key, default, nil -> default
      _key, _default, value -> value
    end)
    |> Map.merge(overrides, fn
      :web_fetch_req_options, config_value, override_value when is_list(override_value) ->
        if override_value == [], do: config_value, else: override_value

      :web_search_adapter_options, config_value, override_value when is_list(override_value) ->
        if override_value == [], do: config_value, else: override_value

      :web_search_req_options, config_value, override_value when is_list(override_value) ->
        if override_value == [], do: config_value, else: override_value

      _key, config_value, nil ->
        config_value

      _key, _config_value, override_value ->
        override_value
    end)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_exit_status(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_exit_status(value, default), do: normalize_positive_integer(value, default)

  defp bash_exit_status(%Jido.Shell.Error{code: {:command, reason}}, policy)
       when reason in [:timeout, :runtime_limit_exceeded] do
    policy["timeout_exit_status"]
  end

  defp bash_exit_status(%Jido.Shell.Error{code: {:command, :cancelled}}, policy) do
    policy["cancelled_exit_status"]
  end

  defp bash_exit_status(
         %Jido.Shell.Error{code: {:command, reason}},
         policy
       )
       when reason in [:crashed, :output_limit_exceeded] do
    policy["crashed_exit_status"]
  end

  defp bash_exit_status(
         %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: code}},
         _policy
       )
       when is_integer(code) and code >= 0 do
    code
  end

  defp bash_exit_status(%Jido.Shell.Error{}, policy), do: policy["failure_exit_status"]

  defp bash_error_type(%Jido.Shell.Error{code: {category, reason}})
       when category == :command and reason in [:timeout, :runtime_limit_exceeded] do
    "command_timeout"
  end

  defp bash_error_type(%Jido.Shell.Error{code: {:vfs, :not_found}}), do: "file_not_found"

  defp bash_error_type(%Jido.Shell.Error{code: {_category, reason}}), do: Atom.to_string(reason)
  defp bash_error_type(_error), do: "bash_error"

  defp bash_error_message(
         %Jido.Shell.Error{code: {category, reason}},
         exit_status
       )
       when category == :command and reason in [:timeout, :runtime_limit_exceeded] do
    "Command timed out with exit status #{exit_status}."
  end

  defp bash_error_message(%Jido.Shell.Error{} = shell_error, exit_status) do
    "#{Exception.message(shell_error)} (exit status #{exit_status})"
  end

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
