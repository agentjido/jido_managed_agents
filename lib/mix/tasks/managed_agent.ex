defmodule Mix.Tasks.ManagedAgent do
  use Mix.Task

  require Ash.Query
  require Logger

  alias JidoManagedAgents.Accounts
  alias JidoManagedAgents.Accounts.User
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentCatalog
  alias JidoManagedAgents.Agents.Environment
  alias JidoManagedAgents.Agents.EnvironmentDefinition
  alias JidoManagedAgents.OSSExample
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventDefinition,
    SessionEventLog,
    SessionRuntime,
    Workspace
  }

  @shortdoc "Runs a local managed-agent smoke session"

  @moduledoc """
  Runs a local managed-agent smoke session against a real provider-backed model.

  The task:

    * ensures the local demo user exists by default
    * imports the sample coding assistant agent YAML
    * creates or reuses a smoke environment
    * creates a fresh session and appends a user message
    * executes `SessionRuntime.run/2`
    * prints the resulting event trace and final assistant message

  Examples:

      mix managed_agent
      mix ma
      mix ma --prompt "Create /notes/check.txt, read it back, and confirm the exact contents."
      mix ma --email demo@example.com --agent-yaml examples/agents/coding-assistant.agent.yaml
  """

  @default_agent_yaml "examples/agents/coding-assistant.agent.yaml"
  @default_environment_json "examples/environments/restricted-cloud.environment.json"

  @default_prompt """
  Use the available tools to create /notes/smoke.txt containing the exact text
  "managed-agent smoke test", then read the file back and confirm the exact
  contents in one sentence.
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          email: :string,
          prompt: :string,
          agent_yaml: :string,
          environment_json: :string,
          title: :string
        ],
        aliases: [
          h: :help,
          e: :email,
          p: :prompt,
          a: :agent_yaml,
          t: :title
        ]
      )

    if argv != [] do
      Mix.raise("mix managed_agent does not accept positional arguments. Use --help for usage.")
    end

    if invalid != [] do
      invalid_flags =
        invalid
        |> Enum.map_join(", ", fn {flag, _value} -> to_string(flag) end)

      Mix.raise("Invalid option(s): #{invalid_flags}")
    end

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      Mix.shell().info(help_footer())
      :ok
    else
      Mix.Task.run("app.start")
      Logger.configure(level: :warning)

      options = normalize_options(opts)
      {user, environment} = resolve_user_and_environment(options)
      agent = import_agent!(user, options.agent_yaml)
      agent_version = Map.fetch!(agent, :latest_version)

      ensure_provider_credentials!(agent_version.model)

      workspace = ensure_workspace!(user, agent)
      archive_previous_smoke_session!(user, workspace)
      session = create_session!(user, agent, agent_version, environment, workspace, options.title)

      append_prompt!(user, session, options.prompt)

      Mix.shell().info("Running managed agent session #{session.id}...")

      case SessionRuntime.run(session.id, user) do
        {:ok, result} ->
          loaded_session = load_session!(user, session.id)

          case runtime_error_details(result) do
            nil ->
              print_summary(user, agent, environment, loaded_session, result, options.prompt)

            details ->
              Mix.raise("""
              Managed agent run emitted a session.error event: #{details}

              Session: #{loaded_session.id}
              Check the session trace in /console/sessions/#{loaded_session.id}.
              """)
          end

        {:error, error} ->
          Mix.raise("""
          Managed agent run failed: #{format_error(error)}

          Check the session trace in /console/sessions after the task exits.
          """)
      end
    end
  end

  defp normalize_options(opts) do
    %{
      email: Keyword.get(opts, :email, OSSExample.demo_user_email()),
      prompt: normalize_prompt(Keyword.get(opts, :prompt, @default_prompt)),
      agent_yaml: Path.expand(Keyword.get(opts, :agent_yaml, @default_agent_yaml)),
      environment_json:
        Path.expand(Keyword.get(opts, :environment_json, @default_environment_json)),
      title: Keyword.get(opts, :title, default_title())
    }
  end

  defp normalize_prompt(prompt) when is_binary(prompt) do
    prompt
    |> String.trim()
    |> case do
      "" -> Mix.raise("Prompt cannot be blank.")
      trimmed -> trimmed
    end
  end

  defp default_title do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    "Managed Agent Smoke #{timestamp}"
  end

  defp resolve_user_and_environment(%{email: email, environment_json: environment_json}) do
    user =
      if email == OSSExample.demo_user_email() do
        OSSExample.seed!().user
      else
        fetch_user!(email)
      end

    {user, ensure_environment!(user, environment_json)}
  end

  defp fetch_user!(email) do
    query =
      User
      |> Ash.Query.for_read(
        :get_by_email,
        %{email: email},
        domain: Accounts,
        authorize?: false
      )

    case Ash.read_one(query) do
      {:ok, %User{} = user} ->
        user

      {:ok, nil} ->
        Mix.raise("""
        User #{email} was not found.

        Use the seeded demo account or create a browser user first:
          mix setup
          mix phx.server
        """)

      {:error, error} ->
        Mix.raise("Failed to load user #{email}: #{inspect(error)}")
    end
  end

  defp ensure_environment!(user, json_path) do
    payload =
      json_path
      |> File.read!()
      |> Jason.decode!()

    attrs =
      case EnvironmentDefinition.normalize_create_payload(payload) do
        {:ok, attrs} ->
          attrs

        {:error, error} ->
          Mix.raise("Invalid environment payload at #{json_path}: #{inspect(error)}")
      end

    case find_environment_by_name(user, attrs.name) do
      %Environment{} = environment ->
        environment

      nil ->
        Environment
        |> Ash.Changeset.for_create(
          :create,
          Map.put(attrs, :user_id, user.id),
          actor: user,
          domain: Agents
        )
        |> Ash.create!()
    end
  end

  defp find_environment_by_name(user, name) do
    Environment
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!()
  end

  defp import_agent!(user, yaml_path) do
    case OSSExample.import_agent_yaml!(user, yaml_path) do
      %Agent{} = agent ->
        agent
        |> reload_agent!(user)

      other ->
        Mix.raise("Expected imported agent, got: #{inspect(other)}")
    end
  end

  defp reload_agent!(agent, user) do
    Agent
    |> Ash.Query.for_read(:by_id, %{id: agent.id}, actor: user, domain: Agents)
    |> Ash.Query.load(AgentCatalog.latest_version_load())
    |> Ash.read_one!()
  end

  defp ensure_provider_credentials!(model) do
    runtime_provider =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime, [])
      |> Keyword.get(:anthropic_compatible_provider, :anthropic)
      |> to_string()

    case required_provider_env(model, runtime_provider) do
      nil ->
        :ok

      env_var ->
        if System.get_env(env_var) in [nil, ""] do
          Mix.raise("""
          Missing #{env_var} for the sample managed-agent run.

          Start from .env.example, load the provider key into your shell, and rerun:
            cp .env.example .env.local
            export #{env_var}=...
            mix ma
          """)
        end
    end
  end

  defp required_provider_env(model, runtime_provider) when is_binary(model) do
    provider =
      if String.contains?(model, ":") do
        model |> String.split(":", parts: 2) |> hd()
      else
        runtime_provider
      end

    provider_env_var(provider)
  end

  defp required_provider_env(%{} = model, runtime_provider) do
    model =
      Map.new(model, fn {key, value} -> {to_string(key), value} end)

    provider =
      case Map.get(model, "provider") do
        provider when is_binary(provider) and provider != "" -> provider
        provider when is_atom(provider) and not is_nil(provider) -> Atom.to_string(provider)
        _other -> runtime_provider
      end

    provider_env_var(provider)
  end

  defp required_provider_env(_model, runtime_provider), do: provider_env_var(runtime_provider)

  defp provider_env_var("anthropic"), do: "ANTHROPIC_API_KEY"
  defp provider_env_var("openai"), do: "OPENAI_API_KEY"
  defp provider_env_var(_provider), do: nil

  defp archive_previous_smoke_session!(user, workspace) do
    case active_workspace_session(user, workspace.id) do
      nil ->
        :ok

      %Session{} = session ->
        if smoke_session?(session) do
          archive_session!(session, user)
          :ok
        else
          Mix.raise("""
          Workspace #{workspace.id} already has an active session (#{session.id}).

          The managed-agent smoke task only auto-archives sessions it created itself.
          Archive the existing session from the UI or the API and rerun `mix ma`.
          """)
        end
    end
  end

  defp ensure_workspace!(user, agent) do
    query =
      Workspace
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
      |> Ash.Query.filter(user_id == ^user.id and agent_id == ^agent.id)

    case Ash.read_one(query) do
      {:ok, %Workspace{} = workspace} ->
        workspace

      {:ok, nil} ->
        Workspace
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            agent_id: agent.id,
            name: "#{agent.name} workspace",
            metadata: %{"source" => "mix.managed_agent"}
          },
          actor: user,
          domain: Sessions
        )
        |> Ash.create(
          upsert?: true,
          upsert_identity: :unique_workspace_per_user_agent,
          upsert_fields: [],
          touch_update_defaults?: false
        )
        |> case do
          {:ok, %Workspace{} = workspace} -> workspace
          {:error, error} -> Mix.raise("Failed to create workspace: #{inspect(error)}")
        end

      {:error, error} ->
        Mix.raise("Failed to resolve workspace: #{inspect(error)}")
    end
  end

  defp active_workspace_session(user, workspace_id) do
    Session
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
    |> Ash.Query.filter(workspace_id == ^workspace_id and status in [:idle, :running])
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read_one!()
  end

  defp smoke_session?(%Session{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "source") == "mix.managed_agent"
  end

  defp smoke_session?(%Session{}), do: false

  defp archive_session!(%Session{} = session, user) do
    session
    |> Ash.Changeset.for_update(:archive, %{}, actor: user, domain: Sessions)
    |> Ash.update!()
  end

  defp create_session!(user, agent, agent_version, environment, workspace, title) do
    attrs = %{
      user_id: user.id,
      agent_id: agent.id,
      agent_version_id: agent_version.id,
      environment_id: environment.id,
      workspace_id: workspace.id,
      title: title,
      metadata: %{"source" => "mix.managed_agent"}
    }

    Session
    |> Ash.Changeset.for_create(:create, attrs, actor: user, domain: Sessions)
    |> Ash.create!()
  end

  defp append_prompt!(user, session, prompt) do
    params = %{
      "type" => "user.message",
      "content" => [%{"type" => "text", "text" => prompt}]
    }

    with {:ok, events} <- SessionEventDefinition.normalize_append_payload(params, session, user),
         {:ok, _appended_events} <- SessionEventLog.append_user_events(session, events, user) do
      :ok
    else
      {:error, error} ->
        Mix.raise("Failed to append the smoke prompt: #{inspect(error)}")
    end
  end

  defp load_session!(user, session_id) do
    session =
      Session
      |> Ash.Query.for_read(:by_id, %{id: session_id}, actor: user, domain: Sessions)
      |> Ash.Query.load([:events, threads: [:events]])
      |> Ash.read_one!()

    %{session | events: Enum.sort_by(session.events || [], & &1.sequence)}
  end

  defp print_summary(user, agent, environment, session, result, prompt) do
    assistant_reply =
      session.events
      |> Enum.filter(&(&1.type == "agent.message"))
      |> List.last()
      |> event_text()

    event_lines =
      session.events
      |> Enum.map_join("\n", fn event ->
        "  [#{event.sequence}] #{event.type}#{event_suffix(event)}"
      end)

    Mix.shell().info("""
    Managed agent smoke run completed.

    User: #{user.email}
    Agent: #{agent.name} (v#{agent.latest_version.version})
    Environment: #{environment.name}
    Session: #{session.id}
    Status: #{session.status}
    Prompt:
      #{prompt}

    Emitted event types:
    #{event_lines}

    Final assistant reply:
      #{assistant_reply}

    Runtime summary:
      Consumed user events: #{length(result.consumed_events)}
      Visible emitted events: #{Enum.map_join(result.emitted_events, ", ", & &1.type)}
    """)
  end

  defp event_suffix(%SessionEvent{type: type} = event)
       when type in ["agent.tool_use", "agent.mcp_tool_use", "agent.custom_tool_use"] do
    " (#{get_in(event.payload || %{}, ["tool_name"]) || "tool"})"
  end

  defp event_suffix(%SessionEvent{}), do: ""

  defp event_text(nil), do: "(no assistant message emitted)"

  defp event_text(%SessionEvent{content: content}) when is_list(content) do
    content
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> "(assistant message had no text payload)"
      text -> text
    end
  end

  defp event_text(_event), do: "(assistant message had no text payload)"

  defp runtime_error_details(result) do
    result.emitted_events
    |> Enum.filter(&(&1.type == "session.error"))
    |> List.last()
    |> case do
      nil ->
        nil

      %SessionEvent{payload: payload} when is_map(payload) ->
        payload["message"] || payload[:message] || inspect(payload)

      %SessionEvent{} = event ->
        inspect(event.payload)
    end
  end

  defp format_error(%{message: message}) when is_binary(message), do: message

  defp format_error(error) when is_exception(error), do: Exception.message(error)

  defp format_error(error), do: inspect(error)

  defp help_footer do
    """

    Options:
      --email USER_EMAIL
      --prompt PROMPT
      --agent-yaml PATH
      --environment-json PATH
      --title SESSION_TITLE
    """
  end
end
