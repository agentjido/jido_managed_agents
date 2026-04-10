defmodule JidoManagedAgents.JidoWorkspaceIntegrationTest do
  use ExUnit.Case, async: false

  test "workspace supports artifact lifecycle and shell commands" do
    workspace_id = "workspace-#{System.unique_integer([:positive])}"
    workspace = Jido.Workspace.new(id: workspace_id)

    assert Jido.Workspace.workspace_id(workspace) == workspace_id
    assert Jido.Workspace.session_id(workspace) == nil

    assert {:ok, workspace} = Jido.Workspace.mkdir(workspace, "/notes")

    assert {:ok, workspace} =
             Jido.Workspace.write(workspace, "/notes/greeting.txt", "Hello, Workspace!")

    assert {:ok, ["notes"]} = Jido.Workspace.list(workspace, "/")
    assert {:ok, "Hello, Workspace!"} = Jido.Workspace.read(workspace, "/notes/greeting.txt")

    assert {:ok, snapshot_id, workspace} = Jido.Workspace.snapshot(workspace)
    assert snapshot_id == "snap-0"

    assert {:ok, workspace} = Jido.Workspace.delete(workspace, "/notes/greeting.txt")
    assert {:error, _reason} = Jido.Workspace.read(workspace, "/notes/greeting.txt")

    assert {:ok, workspace} = Jido.Workspace.restore(workspace, snapshot_id)
    assert {:ok, "Hello, Workspace!"} = Jido.Workspace.read(workspace, "/notes/greeting.txt")

    assert {:ok, "/\n", workspace} = Jido.Workspace.run(workspace, "pwd")
    assert is_binary(Jido.Workspace.session_id(workspace))

    assert {:ok, "Hello, Workspace!", workspace} =
             Jido.Workspace.run(workspace, "cat /notes/greeting.txt")

    assert {:ok, workspace} = Jido.Workspace.close(workspace)
    assert Jido.Workspace.session_id(workspace) == nil
  end
end
