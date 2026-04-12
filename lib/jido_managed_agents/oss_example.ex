defmodule JidoManagedAgents.OSSExample do
  @moduledoc """
  Helpers for the repository's OSS quickstart examples and demo seed data.
  """

  require Ash.Query

  alias AshAuthentication.BcryptProvider
  alias JidoManagedAgents.Accounts
  alias JidoManagedAgents.Accounts.{ApiKey, User}
  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.{Agent, AgentCatalog, AgentDefinition, Environment}
  alias JidoManagedAgents.Integrations
  alias JidoManagedAgents.Integrations.{Credential, CredentialDefinition, Vault}
  alias JidoManagedAgents.Repo
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    Session,
    SessionEvent,
    SessionEventLog,
    SessionRuntime,
    SessionThread,
    SessionThreads,
    SessionVault,
    Workspace
  }

  @demo_email "demo@example.com"
  @demo_password "demo-pass-1234"

  @environment_name "Restricted Demo Sandbox"
  @vault_name "Demo Integrations"
  @ops_vault_name "Engineering Systems"
  @happy_path_title "OSS Happy Path"
  @threaded_title "OSS Threaded Trace"
  @pending_approval_title "Release Approval Queue"

  @spec demo_user_email() :: String.t()
  def demo_user_email, do: @demo_email

  @spec demo_user_password() :: String.t()
  def demo_user_password, do: @demo_password

  @spec seed!() :: map()
  def seed! do
    user = ensure_demo_user!()
    reviewer = import_agent_yaml!(user, example_path("agents/release-reviewer.agent.yaml"))
    coding_agent = import_agent_yaml!(user, example_path("agents/coding-assistant.agent.yaml"))

    coordinator =
      import_seed_agent!(user, "agents/release-coordinator.agent.yaml", fn params ->
        params
        |> Map.put(
          "tools",
          List.wrap(Map.get(params, "tools", [])) ++
            [
              %{
                "type" => "mcp_toolset",
                "mcp_server_name" => "slack",
                "permission_policy" => "always_ask"
              }
            ]
        )
        |> Map.put(
          "mcp_servers",
          List.wrap(Map.get(params, "mcp_servers", [])) ++
            [
              %{
                "type" => "url",
                "name" => "slack",
                "url" => "https://mcp.slack.com/mcp"
              }
            ]
        )
        |> Map.put("callable_agents", [
          %{
            "type" => "agent",
            "id" => reviewer.id,
            "version" => 1,
            "metadata" => %{"handoff" => "release_review", "seeded" => true}
          }
        ])
      end)

    environment = ensure_environment!(user)
    vault = ensure_demo_vault!(user)
    ops_vault = ensure_ops_vault!(user)
    linear_credential = ensure_linear_credential!(user, vault)
    slack_credential = ensure_slack_credential!(user, vault)
    github_credential = ensure_github_credential!(user, ops_vault)
    happy_path_session = ensure_happy_path_session!(user, coding_agent, environment, vault)

    threaded_session =
      ensure_threaded_session!(user, coordinator, reviewer, environment, [vault, ops_vault])

    pending_approval_session =
      ensure_pending_approval_session!(user, coordinator, environment, [vault, ops_vault])

    %{
      user: user,
      agents: [coding_agent, coordinator, reviewer],
      environment: environment,
      vault: vault,
      vaults: [vault, ops_vault],
      credential: linear_credential,
      credentials: [linear_credential, slack_credential, github_credential],
      sessions: [happy_path_session, threaded_session, pending_approval_session]
    }
  end

  @spec create_api_key!(User.t() | String.t(), keyword()) :: map()
  def create_api_key!(actor_or_email, opts \\ [])

  def create_api_key!(%User{} = user, opts) do
    expires_at =
      DateTime.add(
        DateTime.utc_now(),
        Keyword.get(opts, :ttl_days, 30) * 86_400,
        :second
      )

    api_key =
      ApiKey
      |> Ash.Changeset.for_create(
        :create,
        %{user_id: user.id, expires_at: expires_at},
        actor: user,
        domain: Accounts
      )
      |> Ash.create!()

    %{
      user: user,
      expires_at: api_key.expires_at,
      plaintext_api_key: api_key.__metadata__.plaintext_api_key
    }
  end

  def create_api_key!(email, opts) when is_binary(email) do
    email
    |> fetch_user_by_email!()
    |> create_api_key!(opts)
  end

  @spec import_agent_yaml!(User.t() | String.t(), Path.t()) :: Agent.t()
  def import_agent_yaml!(actor_or_email, path)

  def import_agent_yaml!(%User{} = user, path) do
    yaml = File.read!(Path.expand(path))

    with {:ok, params} <- AgentDefinition.parse_yaml(yaml),
         {:ok, %Agent{} = agent} <- create_or_update_agent(user, params) do
      load_agent!(agent.id, user)
    else
      {:error, error} -> raise RuntimeError, "failed to import #{path}: #{inspect(error)}"
    end
  end

  def import_agent_yaml!(email, path) when is_binary(email) do
    email
    |> fetch_user_by_email!()
    |> import_agent_yaml!(path)
  end

  defp import_seed_agent!(%User{} = user, relative_path, transform)
       when is_function(transform, 1) do
    relative_path
    |> example_path()
    |> File.read!()
    |> AgentDefinition.parse_yaml()
    |> case do
      {:ok, %{} = params} ->
        params
        |> transform.()
        |> then(&create_or_update_agent(user, &1))
        |> case do
          {:ok, %Agent{} = agent} ->
            load_agent!(agent.id, user)

          {:error, error} ->
            raise RuntimeError, "failed to import #{relative_path}: #{inspect(error)}"
        end

      {:error, error} ->
        raise RuntimeError, "failed to parse #{relative_path}: #{inspect(error)}"
    end
  end

  @spec run_session!(String.t(), User.t() | String.t()) ::
          {:ok, SessionRuntime.Result.t()} | {:error, term()}
  def run_session!(session_id, actor_or_email)

  def run_session!(session_id, %User{} = user) when is_binary(session_id) do
    SessionRuntime.run(session_id, user)
  end

  def run_session!(session_id, email) when is_binary(session_id) and is_binary(email) do
    session_id
    |> run_session!(fetch_user_by_email!(email))
  end

  @spec example_path(Path.t()) :: Path.t()
  def example_path(relative_path) when is_binary(relative_path) do
    Path.expand("../../examples/#{relative_path}", __DIR__)
  end

  defp ensure_demo_user! do
    {:ok, hashed_password} = BcryptProvider.hash(@demo_password)
    confirmed_at = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO users (id, email, hashed_password, role, confirmed_at)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (email)
      DO UPDATE
      SET hashed_password = EXCLUDED.hashed_password,
          role = EXCLUDED.role,
          confirmed_at = EXCLUDED.confirmed_at
      """,
      [dump_uuid!(Ecto.UUID.generate()), @demo_email, hashed_password, "member", confirmed_at]
    )

    fetch_user_by_email!(@demo_email)
  end

  defp fetch_user_by_email!(email) do
    query =
      User
      |> Ash.Query.for_read(
        :get_by_email,
        %{email: email},
        domain: Accounts,
        authorize?: false
      )

    case Ash.read_one(query) do
      {:ok, %User{} = user} -> user
      {:ok, nil} -> raise RuntimeError, "user #{email} was not found"
      {:error, error} -> raise RuntimeError, "failed to load user #{email}: #{inspect(error)}"
    end
  end

  defp create_or_update_agent(%User{} = user, %{"name" => name} = params) do
    case find_agent_by_name(user, name) do
      nil ->
        AgentCatalog.create_from_params(params, user)

      %Agent{} = existing_agent ->
        AgentCatalog.update_from_params(
          existing_agent,
          Map.put(params, "version", existing_agent.latest_version.version),
          user
        )
    end
  end

  defp create_or_update_agent(_user, _params) do
    {:error, {:invalid_request, "agent YAML must include a name."}}
  end

  defp ensure_environment!(%User{} = user) do
    case find_environment_by_name(user, @environment_name) do
      %Environment{} = environment ->
        environment

      nil ->
        Environment
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            name: @environment_name,
            description:
              "Shared demo runtime with restricted networking and seeded MCP-connected workflows.",
            config: %{
              "type" => "cloud",
              "networking" => %{"type" => "restricted"}
            },
            metadata: %{"example" => "oss", "seeded" => true}
          },
          actor: user,
          domain: Agents
        )
        |> Ash.create!()
    end
  end

  defp ensure_demo_vault!(%User{} = user) do
    ensure_vault!(user, @vault_name,
      description: "Seeded MCP tokens for project coordination workflows.",
      display_metadata: %{"label" => "MCP", "display_name" => @vault_name},
      metadata: %{"example" => "oss", "seeded" => true, "group" => "coordination"}
    )
  end

  defp ensure_ops_vault!(%User{} = user) do
    ensure_vault!(user, @ops_vault_name,
      description: "Sample OAuth credentials for engineering and deployment workflows.",
      display_metadata: %{"label" => "OAuth", "display_name" => @ops_vault_name},
      metadata: %{"example" => "oss", "seeded" => true, "group" => "engineering"}
    )
  end

  defp ensure_vault!(%User{} = user, name, opts) do
    case find_vault_by_name(user, name) do
      %Vault{} = vault ->
        vault

      nil ->
        Vault
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            name: name,
            description: Keyword.fetch!(opts, :description),
            display_metadata: Keyword.fetch!(opts, :display_metadata),
            metadata: Keyword.fetch!(opts, :metadata)
          },
          actor: user,
          domain: Integrations
        )
        |> Ash.create!()
    end
  end

  defp ensure_linear_credential!(%User{} = user, %Vault{} = vault) do
    ensure_static_bearer_credential!(user, vault,
      display_name: "Linear Demo Token",
      mcp_server_url: "https://mcp.linear.app/mcp",
      token: "lin_demo_token_do_not_use",
      metadata: %{"example" => "oss", "provider" => "linear", "seeded" => true}
    )
  end

  defp ensure_slack_credential!(%User{} = user, %Vault{} = vault) do
    ensure_static_bearer_credential!(user, vault,
      display_name: "Slack Demo Token",
      mcp_server_url: "https://mcp.slack.com/mcp",
      token: "xoxb_demo_token_do_not_use",
      metadata: %{"example" => "oss", "provider" => "slack", "seeded" => true}
    )
  end

  defp ensure_github_credential!(%User{} = user, %Vault{} = vault) do
    ensure_oauth_credential!(user, vault,
      display_name: "GitHub MCP OAuth",
      mcp_server_url: "https://api.githubcopilot.com/mcp/",
      access_token: "gho_demo_access_token_do_not_use",
      refresh: %{
        "token_endpoint" => "https://github.com/login/oauth/access_token",
        "client_id" => "Iv1.demoClientId",
        "refresh_token" => "ghr_demo_refresh_token_do_not_use",
        "scope" => "repo workflow read:org",
        "token_endpoint_auth" => %{
          "type" => "client_secret_post",
          "client_secret" => "ghs_demo_client_secret_do_not_use"
        }
      },
      metadata: %{"example" => "oss", "provider" => "github", "seeded" => true}
    )
  end

  defp ensure_static_bearer_credential!(%User{} = user, %Vault{} = vault, opts) do
    mcp_server_url = Keyword.fetch!(opts, :mcp_server_url)

    case find_credential(user, vault.id, :static_bearer, mcp_server_url) do
      %Credential{} = credential ->
        credential

      nil ->
        params = %{
          "display_name" => Keyword.fetch!(opts, :display_name),
          "metadata" => Keyword.fetch!(opts, :metadata),
          "auth" => %{
            "type" => "static_bearer",
            "mcp_server_url" => mcp_server_url,
            "token" => Keyword.fetch!(opts, :token)
          }
        }

        attrs =
          params
          |> CredentialDefinition.normalize_create_payload()
          |> case do
            {:ok, attrs} -> attrs
            {:error, error} -> raise RuntimeError, "invalid seeded credential: #{inspect(error)}"
          end

        Credential
        |> Ash.Changeset.for_create(
          :create,
          Map.put(attrs, :vault_id, vault.id),
          actor: user,
          domain: Integrations
        )
        |> Ash.create!()
    end
  end

  defp ensure_oauth_credential!(%User{} = user, %Vault{} = vault, opts) do
    mcp_server_url = Keyword.fetch!(opts, :mcp_server_url)

    case find_credential(user, vault.id, :mcp_oauth, mcp_server_url) do
      %Credential{} = credential ->
        credential

      nil ->
        params = %{
          "display_name" => Keyword.fetch!(opts, :display_name),
          "metadata" => Keyword.fetch!(opts, :metadata),
          "auth" => %{
            "type" => "mcp_oauth",
            "mcp_server_url" => mcp_server_url,
            "access_token" => Keyword.fetch!(opts, :access_token),
            "refresh" => Keyword.fetch!(opts, :refresh)
          }
        }

        attrs =
          params
          |> CredentialDefinition.normalize_create_payload()
          |> case do
            {:ok, attrs} -> attrs
            {:error, error} -> raise RuntimeError, "invalid seeded credential: #{inspect(error)}"
          end

        Credential
        |> Ash.Changeset.for_create(
          :create,
          Map.put(attrs, :vault_id, vault.id),
          actor: user,
          domain: Integrations
        )
        |> Ash.create!()
    end
  end

  defp ensure_happy_path_session!(
         %User{} = user,
         %Agent{} = agent,
         %Environment{} = environment,
         %Vault{} = vault
       ) do
    case find_session_by_title(user, @happy_path_title) do
      %Session{} = session ->
        session

      nil ->
        version = latest_agent_version!(user, agent.id)
        workspace = ensure_workspace!(user, agent)

        session =
          create_session!(
            user,
            agent,
            version,
            environment,
            workspace,
            @happy_path_title
          )

        create_session_vault!(user, session.id, vault.id, 0)

        primary_thread = ensure_primary_thread!(session, user)

        {:ok, [user_event]} =
          SessionEventLog.append_user_events(
            session,
            [
              %{
                type: "user.message",
                content: [
                  %{
                    "type" => "text",
                    "text" => "Inspect the repository status and summarize the next step."
                  }
                ],
                payload: %{}
              }
            ],
            user
          )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_running",
          [],
          %{"status" => "running"}
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.thinking",
          [%{"type" => "text", "text" => "Reviewing the working tree and recent changes."}],
          %{"provider" => "anthropic", "model" => "claude-sonnet-4-6"}
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.tool_use",
          [
            %{
              "type" => "tool_use",
              "id" => "toolu_git_status",
              "name" => "bash",
              "input" => %{"command" => "git status --short"}
            }
          ],
          %{
            "phase" => "tool_start",
            "tool_use_id" => "toolu_git_status",
            "tool_name" => "bash",
            "input" => %{"command" => "git status --short"}
          }
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.tool_result",
          [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_git_status",
              "content" => [%{"type" => "text", "text" => "README.md\nexamples/\n"}],
              "is_error" => false
            }
          ],
          %{
            "phase" => "tool_complete",
            "tool_use_id" => "toolu_git_status",
            "tool_name" => "bash",
            "input" => %{"command" => "git status --short"},
            "ok" => true,
            "result" => %{"output" => "README.md\nexamples/\n", "exit_status" => 0}
          }
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.message",
          [
            %{
              "type" => "text",
              "text" =>
                "The repo is ready for the OSS walkthrough. Review the new examples first."
            }
          ],
          %{
            "provider" => "anthropic",
            "model" => "claude-sonnet-4-6",
            "usage" => %{"input_tokens" => 18, "output_tokens" => 24, "total_tokens" => 42}
          }
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_idle",
          [],
          %{"status" => "idle"}
        )

        session
        |> mark_user_event_processed!(user_event.sequence)
        |> archive_session!(user)
    end
  end

  defp ensure_threaded_session!(
         %User{} = user,
         %Agent{} = coordinator,
         %Agent{} = reviewer,
         %Environment{} = environment,
         vaults
       ) do
    case find_session_by_title(user, @threaded_title) do
      %Session{} = session ->
        link_session_vaults!(user, session, vaults)
        session

      nil ->
        coordinator_version = latest_agent_version!(user, coordinator.id)
        reviewer_version = latest_agent_version!(user, reviewer.id)
        workspace = ensure_workspace!(user, coordinator)

        session =
          create_session!(
            user,
            coordinator,
            coordinator_version,
            environment,
            workspace,
            @threaded_title
          )

        link_session_vaults!(user, session, vaults)
        primary_thread = ensure_primary_thread!(session, user)

        {:ok, [user_event]} =
          SessionEventLog.append_user_events(
            session,
            [
              %{
                type: "user.message",
                content: [
                  %{"type" => "text", "text" => "Split the release review into a threaded trace."}
                ],
                payload: %{}
              }
            ],
            user
          )

        delegate_thread =
          create_session_thread!(
            user,
            session,
            reviewer.id,
            reviewer_version.id,
            %{parent_thread_id: primary_thread.id}
          )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_running",
          [],
          %{"status" => "running"}
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.thread_created",
          [],
          %{
            "session_thread_id" => delegate_thread.id,
            "parent_thread_id" => primary_thread.id,
            "agent_id" => reviewer.id,
            "agent_version" => reviewer_version.version,
            "model" => reviewer_version.model
          }
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.thread_message_sent",
          [%{"type" => "text", "text" => "Review the release checklist and open risks."}],
          %{
            "from_thread_id" => primary_thread.id,
            "to_thread_id" => delegate_thread.id,
            "tool_use_id" => "toolu_delegate_review",
            "tool_name" => "delegate_release_reviewer",
            "callable_agent_id" => reviewer.id
          }
        )

        create_session_event!(
          user,
          session,
          delegate_thread.id,
          "agent.thread_message_received",
          [%{"type" => "text", "text" => "Review the release checklist and open risks."}],
          %{
            "from_thread_id" => primary_thread.id,
            "tool_use_id" => "toolu_delegate_review",
            "tool_name" => "delegate_release_reviewer",
            "callable_agent_id" => reviewer.id
          },
          nil,
          "thread"
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.message",
          [
            %{
              "type" => "text",
              "text" => "Primary summary ready. See the delegate trace for details."
            }
          ],
          %{
            "provider" => "anthropic",
            "model" => "claude-sonnet-4-6",
            "usage" => %{"input_tokens" => 14, "output_tokens" => 21, "total_tokens" => 35}
          }
        )

        create_session_event!(
          user,
          session,
          delegate_thread.id,
          "agent.message",
          [%{"type" => "text", "text" => "Delegate trace ready with the detailed review notes."}],
          %{
            "provider" => "anthropic",
            "model" => "claude-sonnet-4-6"
          },
          nil,
          "thread"
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_idle",
          [],
          %{"status" => "idle"}
        )

        session
        |> mark_user_event_processed!(user_event.sequence)
        |> archive_session!(user)
    end
  end

  defp ensure_pending_approval_session!(
         %User{} = user,
         %Agent{} = agent,
         %Environment{} = environment,
         vaults
       ) do
    case find_session_by_title(user, @pending_approval_title) do
      %Session{} = session ->
        link_session_vaults!(user, session, vaults)
        session

      nil ->
        version = latest_agent_version!(user, agent.id)
        workspace = ensure_workspace!(user, agent)

        session =
          create_session!(
            user,
            agent,
            version,
            environment,
            workspace,
            @pending_approval_title
          )

        link_session_vaults!(user, session, vaults)
        primary_thread = ensure_primary_thread!(session, user)

        {:ok, [user_event]} =
          SessionEventLog.append_user_events(
            session,
            [
              %{
                type: "user.message",
                content: [
                  %{
                    "type" => "text",
                    "text" =>
                      "Draft a Linear update for the blocked release ticket and pause for approval before sending it."
                  }
                ],
                payload: %{}
              }
            ],
            user
          )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_running",
          [],
          %{"status" => "running"}
        )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "agent.message",
          [
            %{
              "type" => "text",
              "text" =>
                "I drafted a concise Linear follow-up for ENG-482 and I'm waiting for approval before posting it."
            }
          ],
          %{
            "provider" => "anthropic",
            "model" => "claude-opus-4-6",
            "usage" => %{"input_tokens" => 52, "output_tokens" => 39, "total_tokens" => 91}
          }
        )

        tool_use_event =
          create_session_event!(
            user,
            session,
            primary_thread.id,
            "agent.mcp_tool_use",
            [
              %{
                "type" => "tool_use",
                "id" => "toolu_linear_follow_up",
                "name" => "linear.create_comment",
                "input" => %{
                  "issue_id" => "ENG-482",
                  "body" =>
                    "Release checklist is blocked on staging sign-off. I have the rollback notes prepared and can post the external update once approved."
                }
              }
            ],
            %{
              "phase" => "tool_start",
              "tool_use_id" => "toolu_linear_follow_up",
              "tool_name" => "linear.create_comment",
              "mcp_server_name" => "linear",
              "awaiting_confirmation" => true,
              "input" => %{
                "issue_id" => "ENG-482",
                "body" =>
                  "Release checklist is blocked on staging sign-off. I have the rollback notes prepared and can post the external update once approved."
              }
            }
          )

        create_session_event!(
          user,
          session,
          primary_thread.id,
          "session.status_idle",
          [],
          %{"status" => "idle"}
        )

        stop_reason = %{"type" => "requires_action", "event_ids" => [tool_use_event.id]}

        updated_session =
          session
          |> mark_user_event_processed!(user_event.sequence)
          |> put_session_on_hold!(user, tool_use_event.sequence, stop_reason)

        _updated_thread = put_thread_on_hold!(primary_thread, user, stop_reason)
        updated_session
    end
  end

  defp ensure_workspace!(%User{} = user, %Agent{} = agent) do
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
            metadata: %{"example" => "oss", "seeded" => true}
          },
          actor: user,
          domain: Sessions
        )
        |> Ash.create!()

      {:error, error} ->
        raise RuntimeError, "failed to load workspace for #{agent.name}: #{inspect(error)}"
    end
  end

  defp create_session!(
         %User{} = user,
         %Agent{} = agent,
         version,
         %Environment{} = environment,
         %Workspace{} = workspace,
         title
       ) do
    Session
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        agent_id: agent.id,
        agent_version_id: version.id,
        environment_id: environment.id,
        workspace_id: workspace.id,
        title: title,
        metadata: %{"example" => "oss", "seeded" => true}
      },
      actor: user,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp create_session_vault!(%User{} = user, session_id, vault_id, position) do
    query =
      SessionVault
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
      |> Ash.Query.filter(session_id == ^session_id and vault_id == ^vault_id)

    case Ash.read_one(query) do
      {:ok, %SessionVault{} = session_vault} ->
        session_vault

      {:ok, nil} ->
        SessionVault
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            session_id: session_id,
            vault_id: vault_id,
            position: position,
            metadata: %{}
          },
          actor: user,
          domain: Sessions
        )
        |> Ash.create!()

      {:error, error} ->
        raise RuntimeError, "failed to link seeded vault: #{inspect(error)}"
    end
  end

  defp link_session_vaults!(%User{} = user, %Session{} = session, vaults) do
    vaults
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.each(fn {%Vault{} = vault, index} ->
      create_session_vault!(user, session.id, vault.id, index)
    end)

    session
  end

  defp ensure_primary_thread!(%Session{} = session, %User{} = user) do
    case SessionThreads.ensure_primary_thread(session, user, [:agent_version]) do
      {:ok, %SessionThread{} = thread} -> thread
      {:error, error} -> raise RuntimeError, "failed to ensure primary thread: #{inspect(error)}"
    end
  end

  defp create_session_thread!(
         %User{} = user,
         %Session{} = session,
         agent_id,
         agent_version_id,
         attrs
       ) do
    SessionThread
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        session_id: session.id,
        agent_id: agent_id,
        agent_version_id: agent_version_id,
        parent_thread_id: Map.get(attrs, :parent_thread_id),
        role: Map.get(attrs, :role, :delegate),
        status: Map.get(attrs, :status, :idle),
        metadata: %{"example" => "oss", "seeded" => true}
      },
      actor: user,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp create_session_event!(
         %User{} = user,
         %Session{} = session,
         thread_id,
         type,
         content,
         payload,
         stop_reason \\ nil,
         stream_scope \\ "both"
       ) do
    SessionEvent
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_id: user.id,
        session_id: session.id,
        session_thread_id: thread_id,
        sequence: next_event_sequence!(session.id),
        type: type,
        content: content,
        payload: payload,
        stop_reason: stop_reason,
        metadata: %{"stream_scope" => stream_scope, "example" => "oss"}
      },
      actor: user,
      domain: Sessions
    )
    |> Ash.create!()
  end

  defp mark_user_event_processed!(%Session{} = session, sequence) do
    processed_at = DateTime.utc_now()

    Repo.query!(
      """
      UPDATE session_events
      SET processed_at = $2
      WHERE session_id = $1 AND sequence = $3
      """,
      [dump_uuid!(session.id), processed_at, sequence]
    )

    session
  end

  defp put_session_on_hold!(
         %Session{} = session,
         %User{} = user,
         last_processed_event_index,
         stop_reason
       ) do
    session
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: :idle,
        stop_reason: stop_reason,
        last_processed_event_index: max(last_processed_event_index, 1)
      },
      actor: user,
      domain: Sessions
    )
    |> Ash.update!()
  end

  defp put_thread_on_hold!(%SessionThread{} = thread, %User{} = user, stop_reason) do
    thread
    |> Ash.Changeset.for_update(
      :update,
      %{status: :idle, stop_reason: stop_reason},
      actor: user,
      domain: Sessions
    )
    |> Ash.update!()
  end

  defp archive_session!(%Session{} = session, %User{} = user) do
    session
    |> Ash.Changeset.for_update(
      :update,
      %{last_processed_event_index: max(session.last_processed_event_index, 1)},
      actor: user,
      domain: Sessions
    )
    |> Ash.update!()
    |> Ash.Changeset.for_update(:archive, %{}, actor: user, domain: Sessions)
    |> Ash.update!()
  end

  defp find_agent_by_name(%User{} = user, name) do
    query =
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
      |> Ash.Query.filter(name == ^name)
      |> Ash.Query.load(AgentCatalog.latest_version_load())

    Ash.read_one!(query)
  end

  defp find_environment_by_name(%User{} = user, name) do
    query =
      Environment
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Agents)
      |> Ash.Query.filter(name == ^name)

    Ash.read_one!(query)
  end

  defp find_vault_by_name(%User{} = user, name) do
    query =
      Vault
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
      |> Ash.Query.filter(name == ^name)

    Ash.read_one!(query)
  end

  defp find_credential(%User{} = user, vault_id, type, url) do
    query =
      Credential
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Integrations)
      |> Ash.Query.filter(vault_id == ^vault_id and type == ^type and mcp_server_url == ^url)

    Ash.read_one!(query)
  end

  defp find_session_by_title(%User{} = user, title) do
    query =
      Session
      |> Ash.Query.for_read(:read, %{}, actor: user, domain: Sessions)
      |> Ash.Query.filter(title == ^title)
      |> Ash.Query.sort(created_at: :desc)

    Ash.read_one!(query)
  end

  defp latest_agent_version!(%User{} = user, agent_id) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: agent_id}, actor: user, domain: Agents)
      |> Ash.Query.load(:latest_version)

    query
    |> Ash.read_one!()
    |> Map.fetch!(:latest_version)
  end

  defp load_agent!(agent_id, %User{} = user) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: agent_id}, actor: user, domain: Agents)
      |> Ash.Query.load(AgentCatalog.latest_version_load())

    Ash.read_one!(query)
  end

  defp next_event_sequence!(session_id) do
    %Postgrex.Result{rows: [[sequence]]} =
      Repo.query!(
        "SELECT COALESCE(MAX(sequence) + 1, 0) FROM session_events WHERE session_id = $1",
        [dump_uuid!(session_id)]
      )

    sequence
  end

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
