defmodule JidoManagedAgentsWeb.V1.SkillControllerTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  @fixture_dir Path.expand("../../../fixtures/skills/code-review", __DIR__)
  @asset_path Path.join(@fixture_dir, "assets/checklist.md")
  @script_path Path.join(@fixture_dir, "scripts/review.sh")

  test "GET /v1/skills rejects requests without x-api-key", %{conn: conn} do
    conn =
      conn
      |> Helpers.json_conn()
      |> get(~p"/v1/skills")

    assert json_response(conn, 401) == %{
             "error" => %{
               "type" => "authentication_error",
               "message" => "x-api-key header is required."
             }
           }
  end

  test "POST /v1/skills creates a custom skill registry entry from filesystem-backed content", %{
    conn: conn
  } do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/skills", %{
        "source_path" => @fixture_dir,
        "metadata" => %{"team" => "platform"},
        "version_metadata" => %{"audience" => "runtime"},
        "manifest" => %{
          "scripts" => [@script_path],
          "assets" => [@asset_path]
        }
      })

    assert %{
             "id" => skill_id,
             "type" => "skill",
             "skill_type" => "custom",
             "name" => "code-review",
             "description" =>
               "Review code changes for regressions, correctness, and missing tests.",
             "version" => 1,
             "metadata" => %{"team" => "platform"},
             "version_metadata" => %{"audience" => "runtime"},
             "allowed_tools" => ["read", "grep"],
             "manifest" => %{
               "name" => "code-review",
               "description" =>
                 "Review code changes for regressions, correctness, and missing tests.",
               "license" => "MIT",
               "allowed_tools" => ["read", "grep"],
               "version" => "2026.04.09",
               "tags" => ["review", "quality"],
               "metadata" => %{"audience" => "platform"},
               "scripts" => [@script_path],
               "assets" => [@asset_path]
             },
             "source_path" => @fixture_dir,
             "body" => body,
             "archived_at" => nil,
             "created_at" => created_at,
             "updated_at" => updated_at
           } = json_response(conn, 201)

    assert skill_id
    assert body =~ "# Code Review"
    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "GET /v1/skills lists the latest version metadata and GET /v1/skills/:id/versions exposes history",
       %{conn: conn} do
    owner = Helpers.create_user!()
    owner_api_key = Helpers.create_api_key!(owner)

    oldest =
      Helpers.create_skill!(owner, %{
        name: "oldest-skill",
        description: "Original registry entry",
        source_path: @fixture_dir,
        manifest: %{"assets" => [@asset_path]}
      })

    Process.sleep(1)

    newest =
      Helpers.create_skill!(owner, %{
        name: "newest-skill",
        description: "Newest registry entry"
      })

    Helpers.create_skill_version!(owner, oldest, %{
      version: 2,
      version_description: "Latest registry entry",
      source_path: @fixture_dir,
      body: nil,
      allowed_tools: ["read"],
      manifest: %{"scripts" => [@script_path]},
      version_metadata: %{"pinned" => true}
    })

    other = Helpers.create_user!()
    Helpers.create_skill!(other, %{name: "other-skill"})

    index_conn =
      conn
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/skills")

    assert %{
             "data" => [
               %{
                 "id" => newest_id,
                 "type" => "skill",
                 "skill_type" => "custom",
                 "version" => 1
               },
               %{
                 "id" => oldest_id,
                 "type" => "skill",
                 "skill_type" => "custom",
                 "version" => 2,
                 "version_metadata" => %{"pinned" => true},
                 "allowed_tools" => ["read"],
                 "source_path" => @fixture_dir
               }
             ],
             "has_more" => false
           } = json_response(index_conn, 200)

    assert newest_id == newest.id
    assert oldest_id == oldest.id

    show_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/skills/#{oldest.id}")

    assert %{
             "id" => ^oldest_id,
             "version" => 2,
             "source_path" => @fixture_dir,
             "manifest" => %{"scripts" => [@script_path]}
           } = json_response(show_conn, 200)

    versions_conn =
      build_conn()
      |> Helpers.authorized_conn(owner_api_key)
      |> get(~p"/v1/skills/#{oldest.id}/versions")

    assert %{
             "data" => [
               %{
                 "id" => ^oldest_id,
                 "version" => 2,
                 "description" => "Latest registry entry",
                 "version_metadata" => %{"pinned" => true}
               },
               %{
                 "id" => ^oldest_id,
                 "version" => 1,
                 "description" => "Original registry entry"
               }
             ],
             "has_more" => false
           } = json_response(versions_conn, 200)
  end
end
