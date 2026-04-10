defmodule JidoManagedAgents.Sessions.RuntimeWorkspaceTest do
  use ExUnit.Case, async: false

  alias JidoManagedAgents.Sessions.RuntimeWorkspace
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgents.Sessions.Workspace
  alias JidoManagedAgents.Sessions.WorkspaceBackend.LocalVFS
  alias JidoManagedAgents.Sessions.WorkspaceBackend.MemoryVFS

  test "attach_session/1 uses the session's persisted workspace for runtime use" do
    workspace = build_workspace(:memory_vfs)
    session = build_session(workspace)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.attach_session(session)
    assert RuntimeWorkspace.session(runtime_workspace).id == session.id
    assert RuntimeWorkspace.persisted_workspace(runtime_workspace).id == workspace.id
    assert RuntimeWorkspace.backend(runtime_workspace) == MemoryVFS
    assert RuntimeWorkspace.workspace_id(runtime_workspace) == workspace.id
    assert RuntimeWorkspace.shell_session_id(runtime_workspace) == nil
    assert {:ok, runtime_workspace} = RuntimeWorkspace.close(runtime_workspace)
    assert RuntimeWorkspace.shell_session_id(runtime_workspace) == nil
  end

  for {backend, backend_module} <- [memory_vfs: MemoryVFS, local_vfs: LocalVFS] do
    test "#{backend} exposes the same runtime workspace interface for files, snapshots, and shell commands" do
      {workspace_attrs, local_root} = workspace_attrs(unquote(backend))

      register_local_root_cleanup(local_root)

      workspace = build_workspace(unquote(backend), workspace_attrs)
      session = build_session(workspace)

      assert {:ok, runtime_workspace} = RuntimeWorkspace.attach_session(session)
      assert RuntimeWorkspace.backend(runtime_workspace) == unquote(backend_module)

      assert {:ok, runtime_workspace} =
               RuntimeWorkspace.write(runtime_workspace, "/greeting.txt", "Hello, Workspace!")

      assert {:ok, "Hello, Workspace!"} =
               RuntimeWorkspace.read(runtime_workspace, "/greeting.txt")

      assert {:ok, "Hello, Workspace!", runtime_workspace} =
               RuntimeWorkspace.run(runtime_workspace, "cat /greeting.txt")

      assert is_binary(RuntimeWorkspace.shell_session_id(runtime_workspace))

      assert {:ok, runtime_workspace} = RuntimeWorkspace.stop_session(runtime_workspace)
      assert RuntimeWorkspace.shell_session_id(runtime_workspace) == nil

      assert {:ok,
              %{
                "path" => "/greeting.txt",
                "replace_all" => false,
                "replacements" => 1
              }, runtime_workspace} =
               RuntimeWorkspace.edit(
                 runtime_workspace,
                 "/greeting.txt",
                 "Hello",
                 "Hi",
                 replace_all: false
               )

      assert {:ok, "Hi, Workspace!"} = RuntimeWorkspace.read(runtime_workspace, "/greeting.txt")

      assert {:ok, snapshot_id, runtime_workspace} = RuntimeWorkspace.snapshot(runtime_workspace)
      assert snapshot_id == "snap-0"

      assert {:ok, runtime_workspace} =
               RuntimeWorkspace.delete(runtime_workspace, "/greeting.txt")

      assert {:error, :file_not_found} = RuntimeWorkspace.read(runtime_workspace, "/greeting.txt")

      assert {:ok, runtime_workspace} = RuntimeWorkspace.restore(runtime_workspace, snapshot_id)

      assert {:ok, "Hi, Workspace!"} =
               RuntimeWorkspace.read(runtime_workspace, "/greeting.txt")

      assert {:ok, runtime_workspace} = RuntimeWorkspace.mkdir(runtime_workspace, "/notes")

      assert {:ok, runtime_workspace} =
               RuntimeWorkspace.write(runtime_workspace, "/notes/todo.txt", "Workspace TODO")

      assert {:ok, ["/notes", "/notes/todo.txt"]} =
               RuntimeWorkspace.glob(runtime_workspace, "/notes/**")

      assert {:ok, ["/greeting.txt", "/notes/todo.txt"]} =
               RuntimeWorkspace.glob(runtime_workspace, "/**/*.txt")

      assert {:ok,
              [
                %{
                  "path" => "/greeting.txt",
                  "line_number" => 1,
                  "line" => "Hi, Workspace!"
                },
                %{
                  "path" => "/notes/todo.txt",
                  "line_number" => 1,
                  "line" => "Workspace TODO"
                }
              ]} = RuntimeWorkspace.grep(runtime_workspace, "Workspace")

      assert {:ok, ["greeting.txt", "notes"]} = RuntimeWorkspace.list(runtime_workspace, "/")

      assert {:ok, runtime_workspace} = RuntimeWorkspace.close(runtime_workspace)
      assert RuntimeWorkspace.shell_session_id(runtime_workspace) == nil
    end
  end

  for backend <- [:memory_vfs, :local_vfs] do
    test "#{backend} edit and grep surface structured validation failures" do
      {workspace_attrs, local_root} = workspace_attrs(unquote(backend))

      register_local_root_cleanup(local_root)

      workspace = build_workspace(unquote(backend), workspace_attrs)

      assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

      assert {:ok, runtime_workspace} =
               RuntimeWorkspace.write(runtime_workspace, "/greeting.txt", "Hello, Workspace!")

      assert {:error, {:invalid_edit, message}} =
               RuntimeWorkspace.edit(runtime_workspace, "/greeting.txt", "missing", "present")

      assert message =~ "did not match"

      assert {:error, {:invalid_grep, _message}} = RuntimeWorkspace.grep(runtime_workspace, "(")

      assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
    end
  end

  test "local_vfs reopens against the same root after a runtime attachment is closed" do
    {workspace_attrs, local_root} = workspace_attrs(:local_vfs)

    register_local_root_cleanup(local_root)

    workspace = build_workspace(:local_vfs, workspace_attrs)

    assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

    assert {:ok, runtime_workspace} =
             RuntimeWorkspace.write(runtime_workspace, "/persisted.txt", "survives reopen")

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)

    assert {:ok, reopened_workspace} = RuntimeWorkspace.open(workspace)
    assert {:ok, "survives reopen"} = RuntimeWorkspace.read(reopened_workspace, "/persisted.txt")
    assert File.exists?(Path.join(local_root, "persisted.txt"))
    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(reopened_workspace)
  end

  for backend <- [:memory_vfs, :local_vfs] do
    test "#{backend} reopens an already-mounted persisted workspace" do
      {workspace_attrs, local_root} = workspace_attrs(unquote(backend))

      register_local_root_cleanup(local_root)

      workspace = build_workspace(unquote(backend), workspace_attrs)

      assert {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)

      assert {:ok, _runtime_workspace} =
               RuntimeWorkspace.write(
                 runtime_workspace,
                 "/persisted.txt",
                 "available after reopen"
               )

      assert {:ok, reopened_workspace} = RuntimeWorkspace.open(workspace)

      assert {:ok, "available after reopen"} =
               RuntimeWorkspace.read(reopened_workspace, "/persisted.txt")

      assert {:ok, _closed_workspace} = RuntimeWorkspace.close(reopened_workspace)
    end
  end

  defp workspace_attrs(:memory_vfs), do: {%{backend: :memory_vfs, config: %{}}, nil}

  defp workspace_attrs(:local_vfs) do
    root = Path.join(System.tmp_dir!(), "runtime-workspace-#{System.unique_integer([:positive])}")
    {%{backend: :local_vfs, config: %{"root" => root}}, root}
  end

  defp build_workspace(backend, attrs \\ %{}) do
    attrs = Map.new(attrs)

    struct!(Workspace, %{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      name: Map.get(attrs, :name, "workspace-#{System.unique_integer([:positive])}"),
      backend: backend,
      config: Map.get(attrs, :config, %{}),
      state: Map.get(attrs, :state, "ready"),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp build_session(workspace, attrs \\ %{}) do
    attrs = Map.new(attrs)

    struct!(Session, %{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      workspace_id: workspace.id,
      workspace: workspace,
      status: Map.get(attrs, :status, :idle),
      last_processed_event_index: Map.get(attrs, :last_processed_event_index, -1),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  defp register_local_root_cleanup(nil), do: :ok

  defp register_local_root_cleanup(root) do
    on_exit(fn ->
      File.rm_rf(root)
    end)
  end
end
