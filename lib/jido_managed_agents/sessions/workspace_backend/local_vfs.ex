defmodule JidoManagedAgents.Sessions.WorkspaceBackend.LocalVFS do
  @moduledoc """
  Opens a runtime workspace backed by a local filesystem root.

  The root directory may be provided as `workspace.config["root"]` (or
  `workspace.config[:root]`). When omitted, a stable per-workspace path under
  the configured local workspace storage root is used.
  """

  @behaviour JidoManagedAgents.Sessions.WorkspaceBackend.Adapter

  alias JidoManagedAgents.Sessions.Workspace

  @default_storage_root Path.join(System.tmp_dir!(), "jido_managed_agents/local_vfs")

  @impl true
  def open(%Workspace{} = workspace) do
    with {:ok, root} <- root_path(workspace),
         :ok <- File.mkdir_p(root) do
      case Jido.Workspace.new(
             id: workspace.id,
             adapter: Jido.VFS.Adapter.Local,
             adapter_opts: [prefix: root]
           ) do
        %Jido.Workspace.Workspace{} = opened_workspace -> {:ok, opened_workspace}
        {:error, :already_exists} -> {:ok, %Jido.Workspace.Workspace{id: workspace.id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec root_path(Workspace.t()) :: {:ok, String.t()} | {:error, term()}
  def root_path(%Workspace{id: workspace_id, config: config}) do
    case fetch_root(config) do
      nil ->
        {:ok, Path.join(storage_root(), workspace_id)}

      root ->
        normalize_root(root)
    end
  end

  defp fetch_root(%{"root" => root}), do: root
  defp fetch_root(%{root: root}), do: root
  defp fetch_root(%{}), do: nil
  defp fetch_root(_config), do: :invalid

  defp normalize_root(root) when is_binary(root) do
    root
    |> String.trim()
    |> case do
      "" -> {:error, {:invalid_workspace_config, :root}}
      trimmed_root -> {:ok, Path.expand(trimmed_root)}
    end
  end

  defp normalize_root(_root), do: {:error, {:invalid_workspace_config, :root}}

  defp storage_root do
    Application.get_env(
      :jido_managed_agents,
      :local_workspace_storage_root,
      @default_storage_root
    )
    |> Path.expand()
  end
end
