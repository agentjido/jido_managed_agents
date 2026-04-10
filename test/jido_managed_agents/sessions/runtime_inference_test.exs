defmodule JidoManagedAgents.Sessions.RuntimeInferenceTest do
  use ExUnit.Case, async: true

  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Sessions.{RuntimeInference, SessionEvent}
  alias Plug.Conn

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

    Application.put_env(:req_llm, :anthropic_api_key, "test-anthropic-key")

    :ok
  end

  test "generate/2 normalizes Anthropic-compatible models and returns provider-backed text" do
    configure_runtime_inference!(
      success_plug("Plan the next step", "Provider-backed plan for the next step")
    )

    agent_version =
      struct(AgentVersion, %{
        model: %{"id" => "claude-sonnet-4-6", "speed" => "standard"},
        system: "Stay precise.",
        agent_version_skills: []
      })

    event =
      struct(SessionEvent, %{
        content: [%{"type" => "text", "text" => "Plan the next step"}]
      })

    assert {:ok, result} = RuntimeInference.generate(agent_version, event)

    assert result.text == "Provider-backed plan for the next step"
    assert result.provider == "anthropic"
    assert result.model == "claude-sonnet-4-6"

    assert result.usage == %{
             "cached_tokens" => 0,
             "input_tokens" => 12,
             "output_tokens" => 18,
             "reasoning_tokens" => 0,
             "total_tokens" => 30
           }
  end

  test "generate/2 preserves ReqLLM-native model specs and classifies provider failures" do
    configure_runtime_inference!(failure_plug())

    agent_version =
      struct(AgentVersion, %{
        model: %{
          "provider" => "anthropic",
          "id" => "claude-haiku-4-5",
          "base_url" => "https://req-llm-provider.test"
        },
        system: "Stay precise.",
        agent_version_skills: []
      })

    event =
      struct(SessionEvent, %{
        content: [%{"type" => "text", "text" => "Handle the provider failure"}]
      })

    assert {:error, error} = RuntimeInference.generate(agent_version, event)

    assert error.error_type == "provider_error"
    assert error.provider == "anthropic"
    assert error.model == "anthropic:claude-haiku-4-5"
    assert error.message =~ "provider unavailable"
  end

  defp configure_runtime_inference!(plug) do
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

  defp success_plug(expected_prompt, reply_text) do
    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["model"] == "claude-sonnet-4-6"
      assert params["system"] == "Stay precise."
      assert normalized_prompt(params) == expected_prompt

      response =
        Jason.encode!(%{
          "id" => "msg_runtime_inference_success",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "content" => [%{"type" => "text", "text" => reply_text}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 18}
        })

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, response)
    end
  end

  defp failure_plug do
    fn conn ->
      assert conn.host == "req-llm-provider.test"
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["model"] == "claude-haiku-4-5"

      response =
        Jason.encode!(%{
          "error" => %{
            "type" => "api_error",
            "message" => "provider unavailable"
          }
        })

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(500, response)
    end
  end

  defp normalized_prompt(params) do
    get_in(params, ["messages", Access.at(0), "content"]) ||
      get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"])
  end
end
