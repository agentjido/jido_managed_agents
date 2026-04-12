defmodule JidoManagedAgentsWeb.OSSExampleHappyPathTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Agents.AgentDefinition
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.Credential
  alias JidoManagedAgents.Integrations.Vault
  alias JidoManagedAgents.OSSExample
  alias JidoManagedAgents.Sessions
  alias JidoManagedAgents.Sessions.Session
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers

  setup do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_api_key = Application.get_env(:req_llm, :anthropic_api_key)

    on_exit(fn ->
      if previous_runtime == nil do
        Application.delete_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)
      else
        Application.put_env(
          :jido_managed_agents,
          JidoManagedAgents.Sessions.SessionRuntime,
          previous_runtime
        )
      end

      if previous_api_key == nil do
        Application.delete_env(:req_llm, :anthropic_api_key)
      else
        Application.put_env(:req_llm, :anthropic_api_key, previous_api_key)
      end
    end)

    :ok
  end

  test "seed data is idempotent and makes the dashboard resources available" do
    first = OSSExample.seed!()
    second = OSSExample.seed!()

    assert first.user.email == second.user.email
    assert Enum.map(second.agents, & &1.latest_version.version) == [1, 1, 1]

    assert Enum.map(second.sessions, & &1.title) == [
             "OSS Happy Path",
             "OSS Threaded Trace",
             "Release Approval Queue"
           ]

    assert Enum.map(second.vaults, & &1.name) == ["Demo Integrations", "Engineering Systems"]

    sessions =
      Session
      |> Ash.Query.for_read(:read, %{}, actor: second.user, domain: Sessions)
      |> Ash.Query.filter(
        title in ["OSS Happy Path", "OSS Threaded Trace", "Release Approval Queue"]
      )
      |> Ash.read!()

    vaults =
      Vault
      |> Ash.Query.for_read(:read, %{}, actor: second.user, domain: Integrations)
      |> Ash.read!()

    credentials =
      Credential
      |> Ash.Query.for_read(:read, %{}, actor: second.user, domain: Integrations)
      |> Ash.read!()

    assert length(sessions) == 3

    assert Enum.count(sessions, &(get_in(&1.stop_reason || %{}, ["type"]) == "requires_action")) ==
             1

    assert length(vaults) == 2
    assert length(credentials) == 3
  end

  test "example files support the documented happy path", %{conn: conn} do
    prompt = "Inspect the repository status and summarize the next step."
    reply = "The repo is ready for the OSS walkthrough."

    configure_runtime_inference!(prompt, reply)
    assert_example_yamls_parse!()

    user = register_user!()
    %{plaintext_api_key: api_key} = OSSExample.create_api_key!(user, ttl_days: 7)

    imported_agent =
      OSSExample.import_agent_yaml!(
        user,
        OSSExample.example_path("agents/coding-assistant.agent.yaml")
      )

    environment_payload = read_json!("examples/environments/restricted-cloud.environment.json")
    vault_payload = read_json!("examples/requests/demo-vault.create.json")

    credential_payload =
      read_json!("examples/requests/linear-static-bearer.credential.create.json")

    event_payload = read_json!("examples/requests/user-message.event.json")

    environment_conn =
      conn
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/environments", environment_payload)

    assert %{"id" => environment_id} = json_response(environment_conn, 201)

    vault_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults", vault_payload)

    assert %{"id" => vault_id} = json_response(vault_conn, 201)

    credential_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/vaults/#{vault_id}/credentials", credential_payload)

    assert %{
             "vault_id" => ^vault_id,
             "auth" => %{
               "type" => "static_bearer",
               "mcp_server_url" => "https://mcp.linear.app/mcp"
             }
           } = json_response(credential_conn, 201)

    session_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions", %{
        "agent" => imported_agent.id,
        "environment_id" => environment_id,
        "title" => "OSS Quickstart Session",
        "vault_ids" => [vault_id]
      })

    assert %{"id" => session_id} = json_response(session_conn, 201)

    append_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/v1/sessions/#{session_id}/events", event_payload)

    assert %{
             "data" => [
               %{
                 "sequence" => 1,
                 "type" => "user.message"
               }
             ]
           } = json_response(append_conn, 201)

    assert {:ok, result} = OSSExample.run_session!(session_id, user)
    assert Enum.any?(result.emitted_events, &(&1.type == "agent.message"))

    assert Enum.any?(
             result.emitted_events,
             &match?([%{"type" => "text", "text" => ^reply}], &1.content)
           )

    archive_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> post(~p"/v1/sessions/#{session_id}/archive")

    assert %{"id" => ^session_id, "archived_at" => archived_at} = json_response(archive_conn, 200)
    assert is_binary(archived_at)

    stream_conn =
      build_conn()
      |> Helpers.authorized_conn(api_key)
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/v1/sessions/#{session_id}/stream")

    streamed_events = stream_events(stream_conn)

    assert stream_conn.status == 200
    assert Enum.any?(streamed_events, &(&1["type"] == "user.message"))
    assert Enum.any?(streamed_events, &(&1["type"] == "session.status_running"))
    assert Enum.any?(streamed_events, &(&1["type"] == "agent.message"))
    assert Enum.any?(streamed_events, &(&1["type"] == "session.status_idle"))
  end

  defp register_user! do
    email = "oss-example-#{System.unique_integer([:positive])}@example.com"

    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: email,
        password: "supersecret123",
        password_confirmation: "supersecret123"
      },
      domain: JidoManagedAgents.Accounts,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp assert_example_yamls_parse! do
    yaml_paths =
      "examples/agents/*.agent.yaml"
      |> Path.wildcard()
      |> Enum.sort()

    assert length(yaml_paths) >= 3

    Enum.each(yaml_paths, fn path ->
      assert {:ok, %{"name" => name, "model" => %{"id" => model_id}}} =
               path
               |> File.read!()
               |> AgentDefinition.parse_yaml()

      assert is_binary(name)
      assert is_binary(model_id)
    end)
  end

  defp read_json!(relative_path) do
    relative_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp configure_runtime_inference!(expected_prompt, reply_text) do
    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.SessionRuntime,
      anthropic_compatible_provider: :anthropic,
      max_tokens: 1024,
      temperature: 0.2,
      timeout: 30_000,
      req_http_options: [plug: success_anthropic_plug(expected_prompt, reply_text)]
    )
  end

  defp success_anthropic_plug(expected_prompt, reply_text) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      assert get_in(params, ["messages", Access.at(0), "content"]) == expected_prompt or
               get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"]) ==
                 expected_prompt

      response =
        Jason.encode!(%{
          "id" => "msg_oss_example_success",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [%{"type" => "text", "text" => reply_text}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 18}
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response)
    end
  end

  defp stream_events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end
end
