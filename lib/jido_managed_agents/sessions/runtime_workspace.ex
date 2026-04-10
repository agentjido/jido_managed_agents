defmodule JidoManagedAgents.Sessions.RuntimeWorkspace do
  @moduledoc """
  Runtime-facing workspace attachment for sessions and tools.

  This module opens a persisted `Sessions.Workspace` through a backend-specific
  adapter and exposes one consistent interface for runtime code. The caller
  works with a single struct regardless of whether the backing storage is
  `:memory_vfs` or `:local_vfs`.
  """

  require Ash.Query

  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.Workspace
  alias JidoManagedAgents.Sessions.WorkspaceBackend.LocalVFS
  alias JidoManagedAgents.Sessions.WorkspaceBackend.MemoryVFS
  alias Jido.Shell.Error, as: ShellError
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS
  alias Jido.VFS.Stat.Dir
  alias Jido.VFS.Stat.File

  @type backend_module ::
          JidoManagedAgents.Sessions.WorkspaceBackend.Adapter.backend_module()

  @type t :: %__MODULE__{
          backend: backend_module(),
          persisted_workspace: Workspace.t(),
          session: Session.t() | nil,
          handle: Jido.Workspace.t()
        }

  @type workspace_entry :: map()

  @type grep_match :: map()

  defstruct [:backend, :persisted_workspace, :session, :handle]

  @spec open(Workspace.t()) :: {:ok, t()} | {:error, term()}
  def open(%Workspace{} = workspace) do
    with {:ok, backend} <- backend_module(workspace.backend),
         {:ok, handle} <- backend.open(workspace) do
      {:ok,
       %__MODULE__{
         backend: backend,
         persisted_workspace: workspace,
         handle: handle
       }}
    end
  end

  @spec attach_session(Session.t()) :: {:ok, t()} | {:error, term()}
  def attach_session(%Session{} = session) do
    with {:ok, workspace} <- load_workspace(session),
         {:ok, runtime_workspace} <- open(workspace) do
      {:ok, %{runtime_workspace | session: session}}
    end
  end

  @spec backend(t()) :: backend_module()
  def backend(%__MODULE__{backend: backend}), do: backend

  @spec persisted_workspace(t()) :: Workspace.t()
  def persisted_workspace(%__MODULE__{persisted_workspace: workspace}), do: workspace

  @spec session(t()) :: Session.t() | nil
  def session(%__MODULE__{session: session}), do: session

  @spec handle(t()) :: Jido.Workspace.t()
  def handle(%__MODULE__{handle: handle}), do: handle

  @spec workspace_id(t()) :: String.t()
  def workspace_id(%__MODULE__{handle: handle}), do: Jido.Workspace.workspace_id(handle)

  @spec shell_session_id(t()) :: String.t() | nil
  def shell_session_id(%__MODULE__{handle: handle}), do: Jido.Workspace.session_id(handle)

  @spec write(t(), String.t(), iodata()) :: {:ok, t()} | {:error, term()}
  def write(%__MODULE__{} = runtime_workspace, path, content) do
    case Jido.Workspace.write(runtime_workspace.handle, path, content) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(%__MODULE__{handle: handle}, path), do: Jido.Workspace.read(handle, path)

  @spec list(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%__MODULE__{handle: handle}, path \\ "/"), do: Jido.Workspace.list(handle, path)

  @spec stat(t(), String.t()) :: {:ok, File.t() | Dir.t()} | {:error, term()}
  def stat(%__MODULE__{} = runtime_workspace, path) do
    VFS.stat(workspace_id(runtime_workspace), path)
  end

  @spec edit(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map(), t()} | {:error, term()}
  def edit(%__MODULE__{} = runtime_workspace, path, old_text, new_text, opts \\ [])
      when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
    replace_all? = Keyword.get(opts, :replace_all, false)

    with :ok <- validate_edit_old_text(old_text),
         {:ok, content} <- read(runtime_workspace, path),
         {:ok, updated_content, replacements} <-
           replace_content(content, old_text, new_text, replace_all?),
         {:ok, updated_workspace} <- write(runtime_workspace, path, updated_content) do
      {:ok,
       %{
         "path" => path,
         "old_text" => old_text,
         "new_text" => new_text,
         "replace_all" => replace_all?,
         "replacements" => replacements
       }, updated_workspace}
    end
  end

  @spec glob(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def glob(%__MODULE__{} = runtime_workspace, pattern) when is_binary(pattern) do
    with {:ok, normalized_pattern} <- normalize_glob_pattern(pattern),
         {:ok, entries} <- walk(runtime_workspace) do
      matches =
        entries
        |> Enum.map(& &1.path)
        |> Enum.filter(&glob_match?(normalized_pattern, &1))
        |> Enum.sort()

      {:ok, matches}
    end
  end

  @spec grep(t(), String.t(), keyword()) :: {:ok, [grep_match()]} | {:error, term()}
  def grep(%__MODULE__{} = runtime_workspace, pattern, opts \\ []) when is_binary(pattern) do
    path = Keyword.get(opts, :path, "/")
    include = Keyword.get(opts, :include)

    with {:ok, regex} <- compile_grep_regex(pattern),
         {:ok, files} <- files(runtime_workspace, path),
         {:ok, include_matcher} <- build_include_matcher(include) do
      matches =
        files
        |> Enum.filter(&include_matcher.(&1))
        |> Enum.flat_map(fn file_path ->
          case read(runtime_workspace, file_path) do
            {:ok, content} -> grep_file(file_path, content, regex)
            {:error, _reason} -> []
          end
        end)

      {:ok, matches}
    end
  end

  @spec walk(t(), String.t()) :: {:ok, [workspace_entry()]} | {:error, term()}
  def walk(%__MODULE__{} = runtime_workspace, path \\ "/") do
    normalized_path = normalize_workspace_path(path)

    case stat(runtime_workspace, normalized_path) do
      {:ok, %File{}} ->
        {:ok, [%{type: :file, path: normalized_path}]}

      {:ok, %Dir{}} ->
        with {:ok, nested_entries} <- walk_directory(runtime_workspace, normalized_path) do
          {:ok, [%{type: :dir, path: normalized_path} | nested_entries]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec files(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def files(%__MODULE__{} = runtime_workspace, path \\ "/") do
    with {:ok, entries} <- walk(runtime_workspace, path) do
      {:ok,
       entries
       |> Enum.filter(&(&1.type == :file))
       |> Enum.map(& &1.path)
       |> Enum.sort()}
    end
  end

  @spec delete(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def delete(%__MODULE__{} = runtime_workspace, path) do
    case Jido.Workspace.delete(runtime_workspace.handle, path) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def mkdir(%__MODULE__{} = runtime_workspace, path) do
    case Jido.Workspace.mkdir(runtime_workspace.handle, path) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec snapshot(t()) :: {:ok, String.t(), t()} | {:error, term()}
  def snapshot(%__MODULE__{} = runtime_workspace) do
    case Jido.Workspace.snapshot(runtime_workspace.handle) do
      {:ok, snapshot_id, handle} ->
        {:ok, snapshot_id, %{runtime_workspace | handle: handle}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec restore(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def restore(%__MODULE__{} = runtime_workspace, snapshot_id) do
    case Jido.Workspace.restore(runtime_workspace.handle, snapshot_id) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_session(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start_session(%__MODULE__{} = runtime_workspace, opts \\ []) do
    case Jido.Workspace.start_session(runtime_workspace.handle, opts) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run(t(), String.t(), keyword()) :: {:ok, binary(), t()} | {:error, term(), t()}
  def run(%__MODULE__{} = runtime_workspace, command, opts \\ []) do
    case Jido.Workspace.run(runtime_workspace.handle, command, opts) do
      {:ok, output, handle} ->
        {:ok, output, %{runtime_workspace | handle: handle}}

      {:error, reason, handle} ->
        {:error, reason, %{runtime_workspace | handle: handle}}
    end
  end

  @spec run_captured(t(), String.t(), keyword()) ::
          {:ok, %{output: binary()}, t()}
          | {:error, %{output: binary(), shell_error: ShellError.t()}, t()}
  def run_captured(%__MODULE__{} = runtime_workspace, command) when is_binary(command) do
    run_captured(runtime_workspace, command, [])
  end

  @spec run_captured(t(), String.t(), keyword()) ::
          {:ok, %{output: binary()}, t()}
          | {:error, %{output: binary(), shell_error: ShellError.t()}, t()}
  def run_captured(%__MODULE__{} = runtime_workspace, command, opts)
      when is_binary(command) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    execution_context = Keyword.get(opts, :execution_context, %{})

    with {:ok, started_workspace} <- start_session(runtime_workspace),
         session_id when is_binary(session_id) <- shell_session_id(started_workspace),
         {:ok, :subscribed} <- ShellSessionServer.subscribe(session_id, self()) do
      drain_shell_events(session_id)

      result =
        case ShellSessionServer.run_command(
               session_id,
               command,
               execution_context: execution_context
             ) do
          {:ok, :accepted} ->
            collect_shell_result(session_id, command, [], timeout, false)

          {:error, %ShellError{} = error} ->
            {:error, error, ""}
        end

      _ = ShellSessionServer.unsubscribe(session_id, self())

      case result do
        {:ok, output} ->
          {:ok, %{output: output}, started_workspace}

        {:error, %ShellError{} = error, output} ->
          {:error, %{output: output, shell_error: error}, started_workspace}
      end
    end
  end

  @spec stop_session(t()) :: {:ok, t()} | {:error, term()}
  def stop_session(%__MODULE__{} = runtime_workspace) do
    case Jido.Workspace.stop_session(runtime_workspace.handle) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(t()) :: {:ok, t()} | {:error, term()}
  def close(%__MODULE__{} = runtime_workspace) do
    case Jido.Workspace.close(runtime_workspace.handle) do
      {:ok, handle} -> {:ok, %{runtime_workspace | handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec backend_module(atom()) :: {:ok, backend_module()} | {:error, term()}
  def backend_module(:memory_vfs), do: {:ok, MemoryVFS}
  def backend_module(:local_vfs), do: {:ok, LocalVFS}
  def backend_module(backend), do: {:error, {:unsupported_workspace_backend, backend}}

  defp load_workspace(%Session{workspace: %Workspace{} = workspace}), do: {:ok, workspace}

  defp load_workspace(%Session{workspace_id: workspace_id}) when is_binary(workspace_id) do
    Workspace
    |> Ash.Query.for_read(:by_id, %{id: workspace_id}, authorize?: false, domain: Sessions)
    |> Ash.read_one(authorize?: false, domain: Sessions)
    |> case do
      {:ok, %Workspace{} = workspace} -> {:ok, workspace}
      {:ok, nil} -> {:error, :workspace_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp load_workspace(%Session{}), do: {:error, :workspace_not_found}

  defp validate_edit_old_text(""), do: {:error, {:invalid_edit, "old_text must not be empty."}}
  defp validate_edit_old_text(_old_text), do: :ok

  defp replace_content(content, old_text, new_text, replace_all?) do
    replacements = :binary.matches(content, old_text) |> length()

    cond do
      replacements == 0 ->
        {:error, {:invalid_edit, "old_text did not match any content in the target file."}}

      replacements > 1 and not replace_all? ->
        {:error,
         {:invalid_edit,
          "old_text matched multiple locations; set replace_all to true to replace all matches."}}

      replace_all? ->
        {:ok, String.replace(content, old_text, new_text), replacements}

      true ->
        {:ok, String.replace(content, old_text, new_text, global: false), 1}
    end
  end

  defp normalize_glob_pattern(pattern) do
    pattern = String.trim(pattern)

    cond do
      pattern == "" ->
        {:error, {:invalid_glob, "pattern must not be blank."}}

      String.starts_with?(pattern, "/") ->
        {:ok, normalize_workspace_path(pattern)}

      true ->
        {:ok, normalize_workspace_path("/" <> pattern)}
    end
  end

  defp glob_match?(pattern, path) do
    glob_segments = split_workspace_path(pattern)
    path_segments = split_workspace_path(path)
    do_glob_match?(glob_segments, path_segments)
  end

  defp do_glob_match?([], []), do: true
  defp do_glob_match?(["**"], _path_segments), do: true
  defp do_glob_match?([], _path_segments), do: false
  defp do_glob_match?(_glob_segments, []), do: false

  defp do_glob_match?(["**" | rest], path_segments) do
    do_glob_match?(rest, path_segments) or
      (match?([_ | _], path_segments) and do_glob_match?(["**" | rest], tl(path_segments)))
  end

  defp do_glob_match?([glob_segment | rest], [path_segment | path_rest]) do
    segment_match?(glob_segment, path_segment) and do_glob_match?(rest, path_rest)
  end

  defp segment_match?(segment, candidate) do
    segment
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
    |> then(&Regex.match?(Regex.compile!("^" <> &1 <> "$"), candidate))
  end

  defp compile_grep_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {message, at}} -> {:error, {:invalid_grep, "#{message} at #{at}"}}
    end
  end

  defp build_include_matcher(nil), do: {:ok, fn _path -> true end}

  defp build_include_matcher(pattern) when is_binary(pattern) do
    with {:ok, normalized_pattern} <- normalize_glob_pattern(pattern) do
      {:ok, &glob_match?(normalized_pattern, &1)}
    end
  end

  defp build_include_matcher(_pattern) do
    {:error, {:invalid_grep, "include must be a string when provided."}}
  end

  defp grep_file(path, content, regex) do
    content
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, index}, acc ->
      normalized_line = String.trim_trailing(line, "\r")

      if Regex.match?(regex, normalized_line) do
        [
          %{
            "path" => path,
            "line_number" => index,
            "line" => normalized_line
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp walk_directory(runtime_workspace, path) do
    runtime_workspace
    |> workspace_id()
    |> VFS.list_dir(path)
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.sort_by(& &1.name)
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, collected} ->
          child_path = join_workspace_path(path, entry.name)

          case entry do
            %Dir{} ->
              case walk_directory(runtime_workspace, child_path) do
                {:ok, nested_entries} ->
                  {:cont, {:ok, collected ++ [%{type: :dir, path: child_path}] ++ nested_entries}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end

            %File{} ->
              {:cont, {:ok, collected ++ [%{type: :file, path: child_path}]}}

            _other ->
              {:cont, {:ok, collected}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_workspace_path("/", name), do: "/" <> name
  defp join_workspace_path(path, name), do: path <> "/" <> name

  defp split_workspace_path(path) do
    path
    |> normalize_workspace_path()
    |> String.trim_leading("/")
    |> case do
      "" -> []
      trimmed -> String.split(trimmed, "/", trim: true)
    end
  end

  defp normalize_workspace_path(path) do
    path
    |> Path.expand("/")
    |> String.replace(~r{/+}, "/")
    |> case do
      "/" = root -> root
      expanded -> String.trim_trailing(expanded, "/")
    end
  end

  defp collect_shell_result(session_id, expected_command, acc, timeout, started?) do
    receive do
      {:jido_shell_session, ^session_id, {:command_started, ^expected_command}} ->
        collect_shell_result(session_id, expected_command, acc, timeout, true)

      {:jido_shell_session, ^session_id, _event} when not started? ->
        collect_shell_result(session_id, expected_command, acc, timeout, started?)

      {:jido_shell_session, ^session_id, {:output, chunk}} ->
        collect_shell_result(session_id, expected_command, [chunk | acc], timeout, started?)

      {:jido_shell_session, ^session_id, {:cwd_changed, _cwd}} ->
        collect_shell_result(session_id, expected_command, acc, timeout, started?)

      {:jido_shell_session, ^session_id, :command_done} ->
        {:ok, join_output(acc)}

      {:jido_shell_session, ^session_id, {:error, %ShellError{} = error}} ->
        {:error, error, join_output(acc)}

      {:jido_shell_session, ^session_id, :command_cancelled} ->
        {:error, ShellError.command(:cancelled, %{line: expected_command}), join_output(acc)}

      {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
        {:error, ShellError.command(:crashed, %{line: expected_command, reason: reason}),
         join_output(acc)}
    after
      timeout ->
        _ = ShellSessionServer.cancel(session_id)

        {:error, ShellError.command(:timeout, %{line: expected_command, max_runtime_ms: timeout}),
         join_output(acc)}
    end
  end

  defp drain_shell_events(session_id) do
    receive do
      {:jido_shell_session, ^session_id, _event} ->
        drain_shell_events(session_id)
    after
      0 ->
        :ok
    end
  end

  defp join_output(acc) do
    acc
    |> Enum.reverse()
    |> Enum.join()
  end
end
