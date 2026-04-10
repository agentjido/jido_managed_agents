defmodule JidoManagedAgents.Sessions.RuntimeSkillIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Agent.Directive
  alias JidoManagedAgents.Agents.{AgentVersion, AgentVersionSkill, Skill, SkillVersion}

  alias JidoManagedAgents.Sessions.{
    RuntimeInference,
    RuntimeSkills,
    RuntimeWorkspace,
    Session,
    SessionEvent,
    SessionRuntime,
    Workspace
  }

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

    :ok
  end

  test "build_request/1 resolves pinned and latest persisted skill versions explicitly" do
    latest_v1 = build_skill_version(1, "Use the old playbook.")
    latest_v2 = build_skill_version(2, "Use the latest playbook.")
    pinned_v1 = build_skill_version(1, "Use the pinned checklist.")
    pinned_v2 = build_skill_version(2, "Do not use the newer checklist.")

    latest_skill = build_skill("runtime-latest", latest_v2)
    pinned_skill = build_skill("runtime-pinned", pinned_v2)

    agent_version =
      build_agent_version(
        "Stay precise.",
        [],
        [
          build_skill_link(latest_skill, 0, nil),
          build_skill_link(pinned_skill, 1, pinned_v1)
        ]
      )

    [latest_link, pinned_link] =
      agent_version.agent_version_skills
      |> Enum.sort_by(& &1.position)

    assert {:ok, {resolved_latest_skill, resolved_latest_version, :latest}} =
             RuntimeSkills.resolve_skill_version(latest_link)

    assert resolved_latest_skill.id == latest_skill.id
    assert resolved_latest_version.id == latest_v2.id

    assert {:ok, {resolved_pinned_skill, resolved_pinned_version, :pinned}} =
             RuntimeSkills.resolve_skill_version(pinned_link)

    assert resolved_pinned_skill.id == pinned_skill.id
    assert resolved_pinned_version.id == pinned_v1.id

    assert {:ok, request} = RuntimeInference.build_request(agent_version)

    assert Enum.map(request.skills, &{&1.name, &1.vsn}) == [
             {latest_skill.name, "2"},
             {pinned_skill.name, "1"}
           ]

    assert request.system_prompt =~ "Stay precise."
    assert request.system_prompt =~ "## #{latest_skill.name}"
    assert request.system_prompt =~ latest_v2.body
    assert request.system_prompt =~ "## #{pinned_skill.name}"
    assert request.system_prompt =~ pinned_v1.body
    refute request.system_prompt =~ pinned_v2.body
    refute request.system_prompt =~ latest_v1.body
  end

  test "build_request/1 fails clearly when persisted runtime skill links were not preloaded" do
    agent_version =
      struct!(AgentVersion, %{
        model: %{"id" => "claude-sonnet-4-6"},
        system: "Stay precise."
      })

    assert {:error, error} = RuntimeInference.build_request(agent_version)

    assert error.error_type == "validation"
    assert error.provider == "anthropic"
    assert error.model == "anthropic:claude-sonnet-4-6"
    assert error.message == "Persisted runtime skill relationships were not loaded."
  end

  test "build_turn_activity/3 includes persisted skills in the provider-backed runtime request" do
    configure_runtime_inference!(
      success_plug(
        "Apply the incident workflow",
        [
          "Stay precise.",
          "You have access to the following skills:",
          "## incident-response",
          "Use the persisted skill instructions."
        ],
        "Skill-backed runtime answer"
      )
    )

    skill =
      build_skill(
        "incident-response",
        build_skill_version(1, "Use the persisted skill instructions.")
      )

    {session, event, runtime_workspace} =
      build_runtime_fixture("Apply the incident workflow", [
        build_skill_link(skill, 0, skill.latest_version)
      ])

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == ["agent.thinking", "agent.message"]

    assert directive_payload(Enum.at(directives, 1))["content"] == [
             %{
               "type" => "text",
               "text" => "Skill-backed runtime answer"
             }
           ]

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  test "build_turn_activity/3 emits a clear session error when an attached skill cannot resolve a runtime version" do
    invalid_skill = build_skill("missing-runtime-version", nil)

    {session, event, runtime_workspace} =
      build_runtime_fixture("Handle the missing runtime skill", [
        build_skill_link(invalid_skill, 0, nil)
      ])

    assert {:ok, directives, runtime_workspace} =
             SessionRuntime.build_turn_activity(session, [event], runtime_workspace)

    assert Enum.map(directives, &directive_type/1) == ["agent.thinking", "session.error"]

    assert directive_payload(Enum.at(directives, 1))["error_type"] == "validation"
    assert directive_payload(Enum.at(directives, 1))["provider"] == "anthropic"
    assert directive_payload(Enum.at(directives, 1))["model"] == "anthropic:claude-sonnet-4-6"

    assert directive_payload(Enum.at(directives, 1))["message"] ==
             "Persisted runtime skill #{invalid_skill.id} does not have an available version."

    assert {:ok, _closed_workspace} = RuntimeWorkspace.close(runtime_workspace)
  end

  defp build_runtime_fixture(prompt, skill_links) do
    workspace =
      struct!(Workspace, %{
        id: Ecto.UUID.generate(),
        name: "workspace-#{System.unique_integer([:positive])}",
        backend: :memory_vfs,
        config: %{},
        state: "ready",
        metadata: %{}
      })

    session =
      struct!(Session, %{
        id: Ecto.UUID.generate(),
        agent_version: build_agent_version("Stay precise.", [], skill_links)
      })

    event =
      struct!(SessionEvent, %{
        id: Ecto.UUID.generate(),
        sequence: 1,
        type: "user.message",
        content: [%{"type" => "text", "text" => prompt}],
        payload: %{}
      })

    {:ok, runtime_workspace} = RuntimeWorkspace.open(workspace)
    {session, event, runtime_workspace}
  end

  defp build_agent_version(system, tools, skill_links) do
    struct!(AgentVersion, %{
      model: %{"id" => "claude-sonnet-4-6"},
      system: system,
      tools: tools,
      agent_version_skills: skill_links
    })
  end

  defp build_skill(name, latest_version) do
    struct!(Skill, %{
      id: Ecto.UUID.generate(),
      type: :custom,
      name: name,
      description: "#{name} description",
      metadata: %{},
      latest_version: latest_version
    })
  end

  defp build_skill_version(version_number, body) do
    struct!(SkillVersion, %{
      id: Ecto.UUID.generate(),
      version: version_number,
      description: "Skill version #{version_number}",
      body: body,
      source_path: nil,
      allowed_tools: [],
      manifest: %{},
      metadata: %{}
    })
  end

  defp build_skill_link(skill, position, nil) do
    struct!(AgentVersionSkill, %{
      id: Ecto.UUID.generate(),
      position: position,
      metadata: %{},
      skill_id: skill.id,
      skill_version_id: nil,
      skill: skill,
      skill_version: nil
    })
  end

  defp build_skill_link(skill, position, %SkillVersion{} = skill_version) do
    struct!(AgentVersionSkill, %{
      id: Ecto.UUID.generate(),
      position: position,
      metadata: %{},
      skill_id: skill.id,
      skill_version_id: skill_version.id,
      skill: skill,
      skill_version: skill_version
    })
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

  defp success_plug(expected_prompt, expected_system_checks, reply_text) do
    fn conn ->
      assert conn.request_path == "/v1/messages"
      assert Conn.get_req_header(conn, "x-api-key") == ["test-anthropic-key"]

      {:ok, body, conn} = Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["model"] == "claude-sonnet-4-6"
      assert normalized_prompt(params) == expected_prompt

      Enum.each(expected_system_checks, fn expected_fragment ->
        assert params["system"] =~ expected_fragment
      end)

      response =
        Jason.encode!(%{
          "id" => "msg_runtime_skill_success",
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

  defp directive_type(%Directive.Emit{signal: signal}), do: signal.type
  defp directive_payload(%Directive.Emit{signal: signal}), do: signal.data

  defp normalized_prompt(params) do
    get_in(params, ["messages", Access.at(0), "content"]) ||
      get_in(params, ["messages", Access.at(0), "content", Access.at(0), "text"])
  end
end
