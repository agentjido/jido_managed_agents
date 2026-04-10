defmodule JidoManagedAgents.Sessions.SessionRuntimeMCPTest do
  use JidoManagedAgents.DataCase, async: false

  import ExUnit.Assertions

  alias JidoManagedAgents.Sessions.SessionEventLog
  alias JidoManagedAgents.Sessions.SessionRuntime
  alias JidoManagedAgents.Sessions.SessionVault
  alias JidoManagedAgentsWeb.V1ApiTestHelpers, as: Helpers
  alias Plug.Conn

  @valid_mcp_token "valid-docs-token"

  defmodule ProtectedDocsServer do
    use Anubis.Server,
      name: "protected-docs",
      version: "0.1.0",
      capabilities: [:tools]

    alias Anubis.Server.Frame
    alias Anubis.Server.Response

    @impl true
    def init(_client_info, frame) do
      {:ok,
       Frame.register_tool(frame, "lookup_doc",
         description: "Look up a protected document by slug.",
         input_schema: %{slug: {:required, :string}}
       )}
    end

    @impl true
    def handle_tool_call("lookup_doc", %{"slug" => slug}, frame) do
      {:reply,
       Response.tool()
       |> Response.structured(%{
         slug: slug,
         title: "Doc #{slug}",
         excerpt: "Excerpt for #{slug}"
       }), frame}
    end

    def handle_tool_call("lookup_doc", %{slug: slug}, frame),
      do: handle_tool_call("lookup_doc", %{"slug" => slug}, frame)
  end

  defmodule ProtectedDocsMCPPlug do
    import Plug.Conn

    @moduledoc false
    @plug_opts Anubis.Server.Transport.StreamableHTTP.Plug.init(
                 server: JidoManagedAgents.Sessions.SessionRuntimeMCPTest.ProtectedDocsServer
               )

    def init(opts), do: opts

    def call(conn, _opts) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when token == "valid-docs-token" ->
          Anubis.Server.Transport.StreamableHTTP.Plug.call(conn, @plug_opts)

        _other ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
          |> halt()
      end
    end
  end

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_runtime =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime)

    previous_api_key = Application.get_env(:req_llm, :anthropic_api_key)
    previous_endpoints = Application.get_env(:jido_mcp, :endpoints)

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

      if previous_endpoints == nil do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous_endpoints)
      end

      if Process.whereis(Jido.MCP.ClientPool) do
        :sys.replace_state(Jido.MCP.ClientPool, fn state ->
          %{state | endpoints: Jido.MCP.Config.endpoints()}
        end)
      end
    end)

    :ok
  end

  test "run/2 discovers MCP tools with vault-resolved credentials, pauses for approval, and resumes with MCP result events" do
    {mcp_url, _bandit} = start_protected_mcp_server!()

    tool_call = %{
      "id" => "toolu_docs_lookup",
      "name" => "mcp_docs_lookup_doc",
      "input" => %{"slug" => "engineering-handbook"}
    }

    configure_runtime_inference!(
      mcp_approval_resume_plug(
        "Read the engineering handbook",
        tool_call,
        "engineering-handbook",
        "Loaded the handbook through MCP."
      )
    )

    owner = Helpers.create_user!()

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-mcp-agent",
        tools: [%{"type" => "mcp_toolset", "mcp_server_name" => "docs"}],
        mcp_servers: [%{"type" => "url", "name" => "docs", "url" => mcp_url}]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    unmatched_vault = Helpers.create_vault!(owner, %{name: "docs-unmatched"})
    matched_vault = Helpers.create_vault!(owner, %{name: "docs-matched"})

    _unmatched_credential =
      Helpers.create_credential!(owner, unmatched_vault, %{
        mcp_server_url: "#{mcp_url}/other",
        access_token: "ignored-token"
      })

    _matched_credential =
      Helpers.create_credential!(owner, matched_vault, %{
        mcp_server_url: mcp_url,
        access_token: @valid_mcp_token
      })

    attach_vault!(owner, session, unmatched_vault, 0)
    attach_vault!(owner, session, matched_vault, 1)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Read the engineering handbook"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, pause_result} = SessionRuntime.run(session, owner)

    assert Enum.map(pause_result.emitted_events, & &1.type) == [
             "agent.thinking",
             "agent.mcp_tool_use"
           ]

    paused_session = Helpers.get_session!(owner, session.id, [:events])
    blocked_tool_use_event = Enum.at(paused_session.events, 4)

    assert paused_session.stop_reason == %{
             "type" => "requires_action",
             "event_ids" => [blocked_tool_use_event.id]
           }

    assert blocked_tool_use_event.type == "agent.mcp_tool_use"
    assert blocked_tool_use_event.payload["tool_name"] == "mcp_docs_lookup_doc"
    assert blocked_tool_use_event.payload["remote_tool_name"] == "lookup_doc"
    assert blocked_tool_use_event.payload["mcp_server_name"] == "docs"
    assert blocked_tool_use_event.payload["mcp_server_url"] == mcp_url
    assert blocked_tool_use_event.payload["awaiting_confirmation"] == true

    {:ok, [_confirmation_event]} =
      SessionEventLog.append_user_events(
        paused_session,
        [
          %{
            type: "user.tool_confirmation",
            payload: %{"tool_use_id" => blocked_tool_use_event.id, "result" => "allow"}
          }
        ],
        owner
      )

    assert {:ok, resume_result} = SessionRuntime.run(session.id, owner)

    assert Enum.map(resume_result.emitted_events, & &1.type) == [
             "agent.mcp_tool_result",
             "agent.message"
           ]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    mcp_result_event = Enum.at(loaded_session.events, 8)
    message_event = Enum.at(loaded_session.events, 9)

    assert Enum.map(loaded_session.events, & &1.type) == [
             "session.status_idle",
             "user.message",
             "session.status_running",
             "agent.thinking",
             "agent.mcp_tool_use",
             "session.status_idle",
             "user.tool_confirmation",
             "session.status_running",
             "agent.mcp_tool_result",
             "agent.message",
             "session.status_idle"
           ]

    assert mcp_result_event.payload["tool_name"] == "mcp_docs_lookup_doc"
    assert mcp_result_event.payload["remote_tool_name"] == "lookup_doc"
    assert mcp_result_event.payload["mcp_server_name"] == "docs"
    assert mcp_result_event.payload["mcp_server_url"] == mcp_url
    assert mcp_result_event.payload["ok"] == true

    assert get_in(mcp_result_event.payload, ["result", "structuredContent", "slug"]) ==
             "engineering-handbook"

    assert message_event.content == [
             %{"type" => "text", "text" => "Loaded the handbook through MCP."}
           ]

    assert loaded_session.stop_reason == nil
  end

  test "run/2 emits session.error when no session vault credential matches the MCP server URL" do
    {mcp_url, _bandit} = start_protected_mcp_server!()
    configure_runtime_inference!(unexpected_provider_plug())

    owner = Helpers.create_user!()

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-mcp-missing-agent",
        tools: [%{"type" => "mcp_toolset", "mcp_server_name" => "docs"}],
        mcp_servers: [%{"type" => "url", "name" => "docs", "url" => mcp_url}]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    unrelated_vault = Helpers.create_vault!(owner, %{name: "docs-other"})

    _unrelated_credential =
      Helpers.create_credential!(owner, unrelated_vault, %{
        mcp_server_url: "#{mcp_url}/other",
        access_token: @valid_mcp_token
      })

    attach_vault!(owner, session, unrelated_vault, 0)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Try the MCP docs tool"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert session.status == :idle
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = Enum.at(loaded_session.events, 4)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "mcp_credentials_not_found"
    assert error_event.payload["mcp_server_name"] == "docs"
    assert error_event.payload["mcp_server_url"] == mcp_url
    assert loaded_session.stop_reason == nil
  end

  test "run/2 surfaces invalid MCP credentials as session errors instead of crashing" do
    {mcp_url, _bandit} = start_protected_mcp_server!()
    configure_runtime_inference!(unexpected_provider_plug())

    owner = Helpers.create_user!()

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-mcp-invalid-agent",
        tools: [%{"type" => "mcp_toolset", "mcp_server_name" => "docs"}],
        mcp_servers: [%{"type" => "url", "name" => "docs", "url" => mcp_url}]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    invalid_vault = Helpers.create_vault!(owner, %{name: "docs-invalid"})

    _invalid_credential =
      Helpers.create_credential!(owner, invalid_vault, %{
        mcp_server_url: mcp_url,
        access_token: "invalid-token"
      })

    attach_vault!(owner, session, invalid_vault, 0)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Try the protected docs MCP tool"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert session.status == :idle
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = Enum.at(loaded_session.events, 4)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "mcp_tool_discovery_error"
    assert error_event.payload["mcp_server_name"] == "docs"
    assert error_event.payload["mcp_server_url"] == mcp_url
    assert loaded_session.stop_reason == nil
  end

  test "run/2 respects session vault precedence so the first matching MCP credential wins" do
    {mcp_url, _bandit} = start_protected_mcp_server!()
    configure_runtime_inference!(unexpected_provider_plug())

    owner = Helpers.create_user!()

    agent =
      Helpers.create_agent!(owner, %{
        name: "runtime-mcp-precedence-agent",
        tools: [%{"type" => "mcp_toolset", "mcp_server_name" => "docs"}],
        mcp_servers: [%{"type" => "url", "name" => "docs", "url" => mcp_url}]
      })

    agent_version = Helpers.latest_agent_version!(owner, agent)
    environment = Helpers.create_environment!(owner)
    workspace = Helpers.create_workspace!(owner, agent)
    session = Helpers.create_session!(owner, agent, agent_version, environment, workspace)

    first_vault = Helpers.create_vault!(owner, %{name: "docs-first"})
    second_vault = Helpers.create_vault!(owner, %{name: "docs-second"})

    _first_credential =
      Helpers.create_credential!(owner, first_vault, %{
        mcp_server_url: mcp_url,
        access_token: "invalid-token"
      })

    _second_credential =
      Helpers.create_credential!(owner, second_vault, %{
        mcp_server_url: mcp_url,
        access_token: @valid_mcp_token
      })

    attach_vault!(owner, session, first_vault, 0)
    attach_vault!(owner, session, second_vault, 1)

    {:ok, [_user_event]} =
      SessionEventLog.append_user_events(
        session,
        [
          %{
            type: "user.message",
            content: [%{"type" => "text", "text" => "Try the docs MCP tool"}],
            payload: %{}
          }
        ],
        owner
      )

    assert {:ok, result} = SessionRuntime.run(session, owner)
    assert Enum.map(result.emitted_events, & &1.type) == ["agent.thinking", "session.error"]

    loaded_session = Helpers.get_session!(owner, session.id, [:events])
    error_event = Enum.at(loaded_session.events, 4)

    assert error_event.type == "session.error"
    assert error_event.payload["error_type"] == "mcp_tool_discovery_error"
    assert error_event.payload["mcp_server_name"] == "docs"
    assert error_event.payload["mcp_server_url"] == mcp_url
  end

  defp start_protected_mcp_server! do
    port = free_port()

    start_supervised!({ProtectedDocsServer, transport: {:streamable_http, [start: true]}})

    bandit =
      start_supervised!(
        {Bandit, plug: ProtectedDocsMCPPlug, ip: {127, 0, 0, 1}, port: port, startup_log: false}
      )

    {"http://127.0.0.1:#{port}/mcp", bandit}
  end

  defp configure_runtime_inference!(plug) do
    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(
      :jido_managed_agents,
      JidoManagedAgents.Sessions.SessionRuntime,
      anthropic_compatible_provider: :anthropic,
      max_tokens: 1024,
      temperature: 0.2,
      timeout: 30_000,
      req_http_options: [plug: plug]
    )
  end

  defp unexpected_provider_plug do
    fn _conn ->
      raise "provider should not be called when MCP discovery fails"
    end
  end

  defp mcp_approval_resume_plug(
         expected_prompt,
         tool_call,
         expected_result_snippet,
         final_reply_text
       ) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, fn count -> {count, count + 1} end)

      assert params["model"] == "claude-sonnet-4-6"
      assert params["system"] == "Stay precise."
      assert Enum.map(params["tools"], & &1["name"]) == [tool_call["name"]]

      case request_number do
        0 ->
          assert normalized_prompt(params) == expected_prompt

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_mcp_resume_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => tool_call["id"],
                  "name" => tool_call["name"],
                  "input" => tool_call["input"]
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        1 ->
          encoded_request = Jason.encode!(params)

          assert encoded_request =~ tool_call["id"]
          assert encoded_request =~ tool_call["name"]
          assert encoded_request =~ expected_result_snippet

          response =
            Jason.encode!(%{
              "id" => "msg_runtime_mcp_resume_2",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => final_reply_text}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 26, "output_tokens" => 10}
            })

          conn
          |> Conn.put_resp_content_type("application/json")
          |> Conn.send_resp(200, response)

        unexpected_request_number ->
          flunk("unexpected provider request ##{unexpected_request_number + 1}")
      end
    end
  end

  defp normalized_prompt(params) do
    get_in(params, ["messages", Access.at(0), "content"]) ||
      get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"])
  end

  defp attach_vault!(owner, session, vault, position) do
    SessionVault
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: owner.id,
        session_id: session.id,
        vault_id: vault.id,
        position: position,
        metadata: %{}
      },
      actor: owner,
      domain: JidoManagedAgents.Sessions
    )
    |> Ash.create!()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
