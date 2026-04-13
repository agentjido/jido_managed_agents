defmodule JidoManagedAgentsWeb.V1.OpenApiSpecTest do
  use JidoManagedAgentsWeb.ConnCase, async: true

  test "renders the v1 openapi spec", %{conn: conn} do
    spec =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/json/open_api")
      |> json_response(200)

    assert spec["info"]["title"] == "Jido Managed Agents /v1 API"
    assert spec["security"] == [%{"apiKey" => []}]
    assert get_in(spec, ["components", "securitySchemes", "apiKey", "name"]) == "x-api-key"

    assert Map.has_key?(spec["paths"], "/v1/agents")
    assert Map.has_key?(spec["paths"], "/v1/agents/{id}")
    assert Map.has_key?(spec["paths"], "/v1/skills/{id}/versions")
    assert Map.has_key?(spec["paths"], "/v1/vaults/{vault_id}/credentials/{id}")
    assert Map.has_key?(spec["paths"], "/v1/sessions/{id}/threads/{thread_id}/stream")

    assert get_in(spec, ["paths", "/v1/agents", "post", "operationId"]) == "createAgent"
    assert get_in(spec, ["paths", "/v1/sessions", "post", "operationId"]) == "createSession"

    assert get_in(spec, [
             "paths",
             "/v1/sessions/{id}/stream",
             "get",
             "responses",
             "200",
             "content",
             "text/event-stream",
             "schema",
             "type"
           ]) == "string"
  end
end
