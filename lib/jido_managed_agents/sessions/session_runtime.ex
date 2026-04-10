defmodule JidoManagedAgents.Sessions.SessionRuntime do
  @moduledoc """
  Durable session runtime for consuming persisted user events.

  The runtime resolves the workspace through `RuntimeWorkspace`, delegates
  provider-backed user-message turns to `jido_ai` and `req_llm`, emits Jido
  signals for turn activity, and persists the translated activity back into the
  append-only `SessionEvent` log.
  """

  alias Ash.NotLoaded

  require Ash.Query

  alias Jido.Agent.Directive
  alias JidoManagedAgents.Agents.{Agent, AgentVersion}
  alias JidoManagedAgents.Repo
  alias JidoManagedAgents.Sessions

  alias JidoManagedAgents.Sessions.{
    RuntimeInference,
    RuntimeMCP,
    RuntimeTools,
    RuntimeWorkspace,
    Session,
    SessionEvent,
    SessionEventLog,
    SessionLock,
    SessionThread,
    SessionThreads
  }

  alias ReqLLM.{Context, Tool}

  @runtime_source "/sessions/runtime"
  @max_tool_rounds 8
  @delegate_tool_prefix "delegate_to_"
  @delegate_stream_scope :thread
  @session_stream_scope :both

  @user_event_types [
    "user.message",
    "user.interrupt",
    "user.custom_tool_result",
    "user.tool_confirmation"
  ]

  defmodule Result do
    @moduledoc false

    alias JidoManagedAgents.Sessions.{RuntimeWorkspace, Session, SessionEvent}

    @type t :: %__MODULE__{
            session: Session.t(),
            runtime_workspace: RuntimeWorkspace.t() | nil,
            consumed_events: [SessionEvent.t()],
            emitted_events: [SessionEvent.t()]
          }

    @enforce_keys [:session]
    defstruct [:session, :runtime_workspace, consumed_events: [], emitted_events: []]
  end

  defmodule Activity do
    @moduledoc false

    alias JidoManagedAgents.Sessions.RuntimeWorkspace

    @type stop_reason_state :: map() | nil | :recompute

    @type t :: %__MODULE__{
            directives: [Directive.t()],
            runtime_workspace: RuntimeWorkspace.t(),
            resume?: boolean(),
            stop_reason_mode: :preserve | :recompute,
            current_stop_reason: stop_reason_state()
          }

    @enforce_keys [:runtime_workspace]
    defstruct directives: [],
              runtime_workspace: nil,
              resume?: false,
              stop_reason_mode: :preserve,
              current_stop_reason: nil
  end

  @type result :: Result.t()

  @spec run(Session.t() | String.t(), struct() | nil) :: {:ok, result()} | {:error, term()}
  def run(session_or_id, actor \\ nil)

  def run(%Session{} = session, actor), do: run(session.id, actor)

  def run(session_id, actor) when is_binary(session_id) do
    SessionLock.with_lock(session_id, fn ->
      with {:ok, %{session: %Session{} = session, pending_events: pending_events}} <-
             prepare_run(session_id, actor) do
        case pending_events do
          [] -> {:ok, %Result{session: session}}
          _pending_events -> process_pending_events(session, pending_events, actor)
        end
      end
    end)
  end

  @spec build_turn_activity(Session.t(), [SessionEvent.t()], RuntimeWorkspace.t()) ::
          {:ok, [Directive.t()], RuntimeWorkspace.t()}
  def build_turn_activity(
        %Session{} = session,
        pending_events,
        %RuntimeWorkspace{} = runtime_workspace
      )
      when is_list(pending_events) do
    with {:ok, %Activity{} = activity} <-
           build_turn_activity_result(session, pending_events, runtime_workspace, nil) do
      {:ok, activity.directives, activity.runtime_workspace}
    end
  end

  defp prepare_run(session_id, actor) do
    Ash.transact([Session, SessionEvent], fn ->
      with :ok <- lock_session(session_id),
           {:ok, %Session{} = session} <- load_session(session_id, actor),
           :ok <- ensure_runnable(session),
           {:ok, pending_events} <- load_pending_events(session, actor) do
        %{session: session, pending_events: pending_events}
      end
    end)
  end

  defp process_pending_events(%Session{} = session, pending_events, actor) do
    with {:ok, runtime_workspace} <- RuntimeWorkspace.attach_session(session),
         {:ok, %Activity{} = activity} <-
           build_turn_activity_result(session, pending_events, runtime_workspace, actor) do
      finalize_pending_events(session, pending_events, activity, actor)
    end
  end

  defp finalize_pending_events(
         %Session{} = session,
         pending_events,
         %Activity{} = activity,
         actor
       ) do
    Ash.transact([Session, SessionEvent], fn ->
      with :ok <- lock_session(session.id),
           {:ok, %Session{} = locked_session} <- load_session(session.id, actor),
           :ok <- ensure_runnable(locked_session),
           :ok <- ensure_pending_events_available(locked_session.id, pending_events),
           {:ok, %SessionThread{} = primary_thread} <-
             SessionThreads.ensure_primary_thread(locked_session, actor),
           {:ok, %Session{} = running_session} <-
             maybe_transition_to_running(locked_session, activity.resume?, actor),
           {:ok, %SessionThread{} = running_primary_thread} <-
             maybe_transition_thread_to_running(primary_thread, activity.resume?, actor),
           {:ok, emitted_events, runtime_workspace} <-
             persist_turn_activity(
               running_session,
               activity,
               actor,
               thread_id: running_primary_thread.id,
               stream_scope: @session_stream_scope
             ),
           :ok <- mark_events_processed(locked_session.id, pending_events),
           {:ok, _idle_primary_thread} <-
             transition_thread_to_idle(
               running_primary_thread,
               resolve_stop_reason(activity, emitted_events),
               actor
             ),
           {:ok, %Session{} = idle_session} <-
             transition_to_idle(
               running_session,
               pending_events,
               resolve_stop_reason(activity, emitted_events),
               actor
             ) do
        visible_emitted_events =
          Enum.filter(emitted_events, &(SessionEventLog.stream_scope(&1) == :both))

        %Result{
          session: idle_session,
          runtime_workspace: runtime_workspace,
          consumed_events: pending_events,
          emitted_events: visible_emitted_events
        }
      end
    end)
  end

  defp load_session(session_id, actor) do
    Session
    |> Ash.Query.for_read(:by_id, %{id: session_id}, ash_opts(actor))
    |> Ash.Query.load(
      agent_version: [
        agent_version_skills: [:skill_version, skill: [:latest_version]],
        agent_version_callable_agents: [:callable_agent, :callable_agent_version]
      ],
      session_vaults: [vault: [credentials: [:access_token]]]
    )
    |> Ash.read_one()
    |> case do
      {:ok, %Session{} = session} -> {:ok, session}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_runnable(%Session{status: status}) when status in [:idle, :running], do: :ok

  defp ensure_runnable(%Session{}) do
    {:error, {:invalid_request, "Session is not in a runnable state."}}
  end

  defp load_pending_events(%Session{} = session, actor) do
    SessionEvent
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(
      session_id == ^session.id and
        sequence > ^session.last_processed_event_index and
        type in ^@user_event_types and
        is_nil(processed_at)
    )
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read()
  end

  defp ensure_pending_events_available(session_id, pending_events) do
    sequences = Enum.map(pending_events, & &1.sequence)

    case sequences do
      [] ->
        :ok

      _sequences ->
        %Postgrex.Result{rows: [[count]]} =
          Repo.query!(
            """
            SELECT COUNT(*)
            FROM session_events
            WHERE session_id = $1
              AND sequence = ANY($2::integer[])
              AND processed_at IS NULL
            """,
            [dump_uuid!(session_id), sequences]
          )

        if count == length(sequences) do
          :ok
        else
          {:error,
           {:conflict, "Session events changed while the runtime was processing the turn."}}
        end
    end
  end

  defp maybe_transition_to_running(%Session{} = session, false, _actor), do: {:ok, session}

  defp maybe_transition_to_running(%Session{} = session, true, actor),
    do: transition_to_running(session, actor)

  defp transition_to_running(%Session{status: :running} = session, _actor), do: {:ok, session}

  defp transition_to_running(%Session{} = session, actor) do
    session
    |> Ash.Changeset.for_update(:update, %{status: :running, stop_reason: nil}, ash_opts(actor))
    |> Ash.update()
  end

  defp transition_to_idle(%Session{} = session, pending_events, stop_reason, actor) do
    last_processed_event_index =
      pending_events
      |> List.last()
      |> Map.fetch!(:sequence)

    session
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: :idle,
        stop_reason: normalize_runtime_stop_reason(stop_reason),
        last_processed_event_index: last_processed_event_index
      },
      ash_opts(actor)
    )
    |> Ash.update()
  end

  defp maybe_transition_thread_to_running(%SessionThread{} = thread, false, _actor),
    do: {:ok, thread}

  defp maybe_transition_thread_to_running(%SessionThread{} = thread, true, actor) do
    SessionThreads.update_status(thread, :running, nil, actor)
  end

  defp transition_thread_to_idle(%SessionThread{} = thread, stop_reason, actor) do
    SessionThreads.update_status(
      thread,
      :idle,
      normalize_runtime_stop_reason(stop_reason),
      actor
    )
  end

  defp persist_turn_activity(%Session{} = session, %Activity{} = activity, actor, opts) do
    with {:ok, emitted_events} <- persist_directives(session, activity.directives, actor, opts) do
      {:ok, emitted_events, activity.runtime_workspace}
    end
  end

  defp persist_directives(%Session{} = session, directives, actor, opts)
       when is_list(directives) do
    processed_at = DateTime.utc_now()
    next_sequence = next_sequence(session.id)
    thread_id = Keyword.get(opts, :thread_id)
    stream_scope = Keyword.get(opts, :stream_scope, @session_stream_scope)

    directives
    |> Enum.with_index(next_sequence)
    |> Enum.reduce_while({:ok, []}, fn {directive, sequence}, {:ok, acc} ->
      case persist_directive(
             session,
             directive,
             sequence,
             processed_at,
             actor,
             thread_id,
             stream_scope
           ) do
        {:ok, %SessionEvent{} = event} ->
          {:cont, {:ok, [event | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, emitted_events} ->
        {:ok, Enum.reverse(emitted_events)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_turn_activity_result(%Session{} = session, pending_events, runtime_workspace, actor) do
    pending_events
    |> Enum.reduce_while(
      {:ok,
       %Activity{
         runtime_workspace: runtime_workspace,
         current_stop_reason: normalize_runtime_stop_reason(session.stop_reason)
       }},
      fn event, {:ok, %Activity{} = activity} ->
        with {:ok, %Activity{} = event_activity} <-
               build_event_activity(
                 session,
                 event,
                 activity.runtime_workspace,
                 activity.current_stop_reason,
                 actor
               ) do
          {:cont,
           {:ok,
            %Activity{
              directives: activity.directives ++ event_activity.directives,
              runtime_workspace: event_activity.runtime_workspace,
              resume?: activity.resume? || event_activity.resume?,
              stop_reason_mode: event_activity.stop_reason_mode,
              current_stop_reason: event_activity.current_stop_reason
            }}}
        end
      end
    )
  end

  defp build_event_activity(
         %Session{} = session,
         %SessionEvent{type: "user.message"} = event,
         runtime_workspace,
         _current_stop_reason,
         actor
       ) do
    workspace_payload = workspace_payload(runtime_workspace, event)

    turn_result =
      build_user_message_turn(session, event, runtime_workspace, workspace_payload, actor: actor)

    thinking_directive =
      emit_signal(
        "agent.thinking",
        thinking_payload(turn_result, workspace_payload)
      )

    {:ok,
     %Activity{
       directives: [thinking_directive | turn_result.directives],
       runtime_workspace: turn_result.runtime_workspace,
       resume?: true,
       stop_reason_mode: turn_result.stop_reason_mode,
       current_stop_reason: :recompute
     }}
  end

  defp build_event_activity(
         %Session{} = session,
         %SessionEvent{type: "user.custom_tool_result"} = event,
         runtime_workspace,
         current_stop_reason,
         actor
       ) do
    build_custom_tool_result_activity(
      session,
      event,
      runtime_workspace,
      current_stop_reason,
      actor
    )
  end

  defp build_event_activity(
         %Session{} = session,
         %SessionEvent{type: "user.tool_confirmation"} = event,
         runtime_workspace,
         current_stop_reason,
         actor
       ) do
    build_tool_confirmation_activity(
      session,
      event,
      runtime_workspace,
      current_stop_reason,
      actor
    )
  end

  defp build_event_activity(
         _session,
         %SessionEvent{} = event,
         runtime_workspace,
         current_stop_reason,
         _actor
       ) do
    {:ok,
     error_activity(
       runtime_workspace,
       %{
         "message" => "Session runtime skeleton does not yet handle #{event.type}.",
         "unsupported_event_type" => event.type
       }
       |> Map.merge(workspace_payload(runtime_workspace, event)),
       current_stop_reason
     )}
  end

  defp build_user_message_turn(session, event, runtime_workspace, workspace_payload, opts) do
    with {:ok, tool_runtime} <- resolve_tool_runtime(session, opts) do
      if tool_runtime.definitions == [] and Keyword.get(opts, :current_thread_role) != :delegate do
        build_text_only_turn(session, event, runtime_workspace, workspace_payload)
      else
        build_tool_enabled_turn(
          session,
          event,
          runtime_workspace,
          workspace_payload,
          tool_runtime,
          opts
        )
      end
    else
      {:error, error} ->
        error_turn(runtime_workspace, workspace_payload, error, nil, nil)
    end
  end

  defp build_text_only_turn(session, event, runtime_workspace, workspace_payload) do
    case RuntimeInference.generate(session.agent_version, event) do
      {:ok, inference} ->
        %{
          runtime_workspace: runtime_workspace,
          provider: inference.provider,
          model: inference.model,
          thinking: inference.thinking || "Dispatching provider-backed inference.",
          stop_reason_mode: :recompute,
          directives: [
            emit_signal(
              "agent.message",
              %{
                "content" => [%{"type" => "text", "text" => inference.text}],
                "phase" => "turn_complete",
                "provider" => inference.provider,
                "model" => inference.model,
                "usage" => inference.usage
              }
              |> Map.merge(workspace_payload)
            )
          ]
        }

      {:error, error} ->
        error_turn(runtime_workspace, workspace_payload, error, nil, nil)
    end
  end

  defp build_tool_enabled_turn(
         session,
         event,
         runtime_workspace,
         workspace_payload,
         tool_runtime,
         opts
       ) do
    case prompt_from_event(event) do
      {:ok, prompt} ->
        context = Context.new([Context.user(prompt)])

        execute_tool_rounds(
          session,
          tool_runtime,
          context,
          runtime_workspace,
          workspace_payload,
          [],
          %{provider: nil, model: nil, thinking: nil},
          0,
          opts
        )

      {:error, error} ->
        error_turn(runtime_workspace, workspace_payload, error, nil, nil)
    end
  end

  defp execute_tool_rounds(
         session,
         tool_runtime,
         context,
         runtime_workspace,
         workspace_payload,
         directives,
         meta,
         round_count,
         opts
       ) do
    cond do
      round_count >= @max_tool_rounds ->
        error_turn(
          runtime_workspace,
          workspace_payload,
          %{
            "error_type" => "tool_loop_limit",
            "message" => "Exceeded #{@max_tool_rounds} provider tool rounds in one turn."
          },
          meta.provider,
          meta.model,
          directives,
          meta.thinking
        )

      true ->
        case RuntimeInference.chat(session.agent_version, context,
               tools: tool_runtime.definitions
             ) do
          {:ok, response, request} ->
            classification = ReqLLM.Response.classify(response)

            next_meta = %{
              provider: meta.provider || request.provider,
              model: meta.model || response.model || request.model_label,
              thinking:
                meta.thinking ||
                  normalize_thinking_text(classification.thinking) ||
                  "Dispatching provider-backed inference."
            }

            case classification.type do
              :final_answer ->
                %{
                  runtime_workspace: runtime_workspace,
                  provider: next_meta.provider,
                  model: next_meta.model,
                  thinking: next_meta.thinking,
                  stop_reason_mode: :recompute,
                  directives:
                    directives ++
                      [
                        emit_signal(
                          "agent.message",
                          %{
                            "content" => [
                              %{
                                "type" => "text",
                                "text" => normalize_response_text(classification.text)
                              }
                            ],
                            "phase" => "turn_complete",
                            "provider" => next_meta.provider,
                            "model" => next_meta.model,
                            "usage" => normalize_usage(ReqLLM.Response.usage(response))
                          }
                          |> Map.merge(workspace_payload)
                        )
                      ]
                }

              :tool_calls ->
                case execute_tool_calls(
                       session,
                       tool_runtime,
                       classification.tool_calls,
                       response_context(response, context),
                       runtime_workspace,
                       workspace_payload,
                       directives,
                       opts
                     ) do
                  {:continue, next_context, updated_workspace, updated_directives} ->
                    execute_tool_rounds(
                      session,
                      tool_runtime,
                      next_context,
                      updated_workspace,
                      workspace_payload,
                      updated_directives,
                      next_meta,
                      round_count + 1,
                      opts
                    )

                  {:pause, updated_workspace, updated_directives} ->
                    %{
                      runtime_workspace: updated_workspace,
                      provider: next_meta.provider,
                      model: next_meta.model,
                      thinking: next_meta.thinking,
                      stop_reason_mode: :recompute,
                      directives: updated_directives
                    }

                  {:error, error, updated_workspace, updated_directives} ->
                    error_turn(
                      updated_workspace,
                      workspace_payload,
                      error,
                      next_meta.provider,
                      next_meta.model,
                      updated_directives,
                      next_meta.thinking
                    )
                end
            end

          {:error, error} ->
            error_turn(
              runtime_workspace,
              workspace_payload,
              error,
              meta.provider,
              meta.model,
              directives,
              meta.thinking
            )
        end
    end
  end

  defp execute_tool_calls(
         session,
         tool_runtime,
         tool_calls,
         context,
         runtime_workspace,
         workspace_payload,
         directives,
         opts
       ) do
    Enum.reduce_while(
      tool_calls,
      {:continue, context, runtime_workspace, directives, false},
      fn tool_call, {:continue, context_acc, workspace_acc, directives_acc, blocking_custom?} ->
        normalized_tool_call = ReqLLM.ToolCall.from_map(tool_call)
        custom_tool? = custom_tool_enabled?(session, normalized_tool_call.name)
        mcp_tool_entry = mcp_tool_entry(tool_runtime, normalized_tool_call.name)
        delegate_tool_entry = delegate_tool_entry(tool_runtime, normalized_tool_call.name)

        cond do
          delegate_tool_call?(normalized_tool_call.name) && nested_delegation?(opts) ->
            {:halt,
             {:error, nested_delegation_error(normalized_tool_call.name), workspace_acc,
              directives_acc}}

          delegate_tool_entry ->
            case execute_delegate_tool_call(
                   session,
                   delegate_tool_entry,
                   normalized_tool_call,
                   workspace_acc,
                   directives_acc,
                   opts
                 ) do
              {:ok, result, updated_workspace, updated_directives} ->
                next_context = append_tool_result(context_acc, result)

                {:cont, {:continue, next_context, updated_workspace, updated_directives, false}}

              {:error, error, updated_workspace, updated_directives} ->
                {:halt, {:error, error, updated_workspace, updated_directives}}
            end

          custom_tool? ->
            {:cont,
             {:continue, context_acc, workspace_acc,
              directives_acc ++
                [custom_tool_use_directive(normalized_tool_call, workspace_payload)], true}}

          blocking_custom? ->
            {:cont, {:continue, context_acc, workspace_acc, directives_acc, true}}

          true ->
            permission_policy =
              tool_permission_policy(session, tool_runtime.mcp_tools, normalized_tool_call.name)

            tool_use_directive =
              if mcp_tool_entry do
                mcp_tool_use_directive(
                  normalized_tool_call,
                  mcp_tool_entry,
                  workspace_payload,
                  awaiting_confirmation?: permission_policy == "always_ask"
                )
              else
                tool_use_directive(
                  normalized_tool_call,
                  workspace_payload,
                  awaiting_confirmation?: permission_policy == "always_ask"
                )
              end

            if permission_policy == "always_ask" do
              {:halt, {:pause, workspace_acc, directives_acc ++ [tool_use_directive]}}
            else
              case execute_runtime_tool(
                     session,
                     tool_runtime.mcp_tools,
                     workspace_acc,
                     normalized_tool_call
                   ) do
                {:ok, result, updated_workspace} ->
                  tool_result_directive =
                    tool_result_directive(
                      result,
                      workspace_payload,
                      mcp?: not is_nil(mcp_tool_entry)
                    )

                  next_context = append_tool_result(context_acc, result)

                  {:cont,
                   {:continue, next_context, updated_workspace,
                    directives_acc ++ [tool_use_directive, tool_result_directive], false}}

                {:error, result, updated_workspace} ->
                  tool_result_directive =
                    tool_result_directive(
                      result,
                      workspace_payload,
                      mcp?: not is_nil(mcp_tool_entry)
                    )

                  next_context = append_tool_result(context_acc, result)

                  {:cont,
                   {:continue, next_context, updated_workspace,
                    directives_acc ++ [tool_use_directive, tool_result_directive], false}}
              end
            end
        end
      end
    )
    |> case do
      {:continue, _next_context, updated_workspace, updated_directives, true} ->
        {:pause, updated_workspace, updated_directives}

      {:continue, next_context, updated_workspace, updated_directives, false} ->
        {:continue, next_context, updated_workspace, updated_directives}

      {:pause, updated_workspace, updated_directives} ->
        {:pause, updated_workspace, updated_directives}

      {:error, error, updated_workspace, updated_directives} ->
        {:error, error, updated_workspace, updated_directives}
    end
  end

  defp append_tool_result(context, result) do
    Context.append(
      context,
      Context.tool_result(
        result["tool_use_id"],
        result["tool_name"],
        RuntimeTools.tool_result_content(result)
      )
    )
  end

  defp tool_use_directive(%{id: id, name: name, arguments: arguments}, workspace_payload, opts) do
    emit_signal(
      "agent.tool_use",
      %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" => stringify(arguments)
          }
        ],
        "phase" => "tool_start",
        "tool_use_id" => id,
        "tool_name" => name,
        "input" => stringify(arguments)
      }
      |> maybe_put("awaiting_confirmation", Keyword.get(opts, :awaiting_confirmation?))
      |> Map.merge(workspace_payload)
    )
  end

  defp mcp_tool_use_directive(
         %{id: id, name: name, arguments: arguments},
         tool_entry,
         workspace_payload,
         opts
       ) do
    emit_signal(
      "agent.mcp_tool_use",
      %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" => stringify(arguments)
          }
        ],
        "phase" => "tool_start",
        "tool_use_id" => id,
        "tool_name" => name,
        "input" => stringify(arguments),
        "remote_tool_name" => tool_entry.remote_tool_name,
        "mcp_server_name" => tool_entry.mcp_server_name,
        "mcp_server_url" => tool_entry.mcp_server_url,
        "mcp_server_headers" => Map.get(tool_entry, :headers, %{}),
        "permission_policy" => tool_entry.permission_policy
      }
      |> maybe_put("awaiting_confirmation", Keyword.get(opts, :awaiting_confirmation?))
      |> Map.merge(workspace_payload)
    )
  end

  defp custom_tool_use_directive(%{id: id, name: name, arguments: arguments}, workspace_payload) do
    emit_signal(
      "agent.custom_tool_use",
      %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" => stringify(arguments)
          }
        ],
        "phase" => "tool_start",
        "tool_use_id" => id,
        "tool_name" => name,
        "input" => stringify(arguments)
      }
      |> Map.merge(workspace_payload)
    )
  end

  defp tool_result_directive(result, workspace_payload, opts) do
    emit_signal(
      if(Keyword.get(opts, :mcp?, false), do: "agent.mcp_tool_result", else: "agent.tool_result"),
      %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => result["tool_use_id"],
            "content" => RuntimeTools.tool_result_content(result),
            "is_error" => not result["ok"]
          }
        ],
        "phase" => "tool_complete",
        "tool_use_id" => result["tool_use_id"],
        "tool_name" => result["tool_name"],
        "input" => result["input"],
        "ok" => result["ok"],
        "result" => Map.get(result, "result"),
        "error" => Map.get(result, "error"),
        "remote_tool_name" => Map.get(result, "remote_tool_name"),
        "mcp_server_name" => Map.get(result, "mcp_server_name"),
        "mcp_server_url" => Map.get(result, "mcp_server_url")
      }
      |> Map.merge(workspace_payload)
    )
  end

  defp build_custom_tool_result_activity(
         %Session{} = session,
         %SessionEvent{} = event,
         runtime_workspace,
         current_stop_reason,
         actor
       ) do
    with {:ok, custom_tool_result} <- normalize_custom_tool_result_payload(event.payload),
         {:ok, remaining_event_ids} <-
           resolve_pending_custom_tool_result(
             current_stop_reason,
             custom_tool_result.custom_tool_use_id
           ),
         {:ok, %SessionEvent{} = custom_tool_use_event} <-
           load_custom_tool_use_event(session.id, custom_tool_result.custom_tool_use_id, actor),
         :ok <- ensure_custom_tool_use_event(custom_tool_use_event) do
      case remaining_event_ids do
        [] ->
          with {:ok, %SessionEvent{} = trigger_event} <-
                 load_custom_tool_trigger_event(session.id, custom_tool_use_event, actor),
               {:ok, context} <-
                 rebuild_custom_tool_context(session, trigger_event, event.sequence, actor),
               {:ok, turn_result} <-
                 continue_after_custom_tool_results(
                   session,
                   custom_tool_use_event,
                   trigger_event,
                   context,
                   runtime_workspace
                 ) do
            {:ok,
             %Activity{
               directives: turn_result.directives,
               runtime_workspace: turn_result.runtime_workspace,
               resume?: true,
               stop_reason_mode: turn_result.stop_reason_mode,
               current_stop_reason: :recompute
             }}
          end

        remaining_event_ids ->
          {:ok,
           %Activity{
             directives: [],
             runtime_workspace: runtime_workspace,
             resume?: false,
             stop_reason_mode: :preserve,
             current_stop_reason: %{
               "type" => "requires_action",
               "event_ids" => remaining_event_ids
             }
           }}
      end
    else
      {:error, %{} = error} ->
        {:ok,
         error_activity(
           runtime_workspace,
           Map.merge(error, workspace_payload(runtime_workspace, event)),
           current_stop_reason
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp continue_after_custom_tool_results(
         %Session{} = session,
         %SessionEvent{} = custom_tool_use_event,
         %SessionEvent{} = trigger_event,
         %Context{} = context,
         runtime_workspace
       ) do
    with {:ok, tool_runtime} <- resolve_tool_runtime(session) do
      {:ok,
       execute_tool_rounds(
         session,
         tool_runtime,
         context,
         runtime_workspace,
         resume_workspace_payload(custom_tool_use_event, trigger_event),
         [],
         %{provider: nil, model: nil, thinking: nil},
         1,
         []
       )}
    end
  end

  defp normalize_custom_tool_result_payload(payload) when is_map(payload) do
    payload = stringify(payload)

    case Map.get(payload, "custom_tool_use_id") do
      custom_tool_use_id
      when is_binary(custom_tool_use_id) and byte_size(custom_tool_use_id) > 0 ->
        {:ok, %{custom_tool_use_id: custom_tool_use_id}}

      _other ->
        {:error,
         %{
           "error_type" => "invalid_custom_tool_result",
           "message" => "Custom tool result payload must include custom_tool_use_id."
         }}
    end
  end

  defp normalize_custom_tool_result_payload(_payload) do
    {:error,
     %{
       "error_type" => "invalid_custom_tool_result",
       "message" => "Custom tool result payload must be an object."
     }}
  end

  defp resolve_pending_custom_tool_result(
         %{"type" => "requires_action", "event_ids" => event_ids},
         custom_tool_use_id
       )
       when is_list(event_ids) do
    if custom_tool_use_id in event_ids do
      {:ok, List.delete(event_ids, custom_tool_use_id)}
    else
      {:error, invalid_custom_tool_result(custom_tool_use_id, :not_pending)}
    end
  end

  defp resolve_pending_custom_tool_result(:recompute, custom_tool_use_id) do
    {:error, invalid_custom_tool_result(custom_tool_use_id, :not_pending)}
  end

  defp resolve_pending_custom_tool_result(_stop_reason, custom_tool_use_id) do
    {:error, invalid_custom_tool_result(custom_tool_use_id, :not_waiting)}
  end

  defp invalid_custom_tool_result(custom_tool_use_id, :not_pending) do
    %{
      "error_type" => "invalid_custom_tool_result",
      "message" => "Custom tool result does not reference a pending custom tool request.",
      "custom_tool_use_id" => custom_tool_use_id
    }
  end

  defp invalid_custom_tool_result(custom_tool_use_id, :not_waiting) do
    %{
      "error_type" => "invalid_custom_tool_result",
      "message" => "Session is not waiting on a custom tool result.",
      "custom_tool_use_id" => custom_tool_use_id
    }
  end

  defp load_custom_tool_use_event(session_id, event_id, actor) do
    SessionEvent
    |> Ash.Query.for_read(:by_id, %{id: event_id}, ash_opts(actor))
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.read_one()
    |> case do
      {:ok, %SessionEvent{} = event} ->
        {:ok, event}

      {:ok, nil} ->
        {:error,
         %{
           "error_type" => "invalid_custom_tool_result",
           "message" => "Custom tool result references an unknown custom tool use event."
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_custom_tool_use_event(%SessionEvent{type: "agent.custom_tool_use"}), do: :ok

  defp ensure_custom_tool_use_event(%SessionEvent{}) do
    {:error,
     %{
       "error_type" => "invalid_custom_tool_result",
       "message" => "Custom tool result must reference an agent.custom_tool_use event."
     }}
  end

  defp load_custom_tool_trigger_event(session_id, %SessionEvent{} = custom_tool_use_event, actor) do
    custom_tool_use_event
    |> stringify_payload()
    |> Map.get("trigger_event_id")
    |> case do
      trigger_event_id when is_binary(trigger_event_id) ->
        SessionEvent
        |> Ash.Query.for_read(:by_id, %{id: trigger_event_id}, ash_opts(actor))
        |> Ash.Query.filter(session_id == ^session_id)
        |> Ash.read_one()
        |> case do
          {:ok, %SessionEvent{} = event} ->
            {:ok, event}

          {:ok, nil} ->
            {:error,
             %{
               "error_type" => "invalid_custom_tool_result",
               "message" => "Blocked custom tool use is missing its triggering user message."
             }}

          {:error, error} ->
            {:error, error}
        end

      _other ->
        {:error,
         %{
           "error_type" => "invalid_custom_tool_result",
           "message" => "Blocked custom tool use is missing its triggering user message."
         }}
    end
  end

  defp rebuild_custom_tool_context(session, trigger_event, max_sequence, actor) do
    with {:ok, prompt} <- prompt_from_event(trigger_event),
         {:ok, turn_events} <-
           load_custom_tool_turn_events(session, trigger_event, max_sequence, actor) do
      custom_tool_use_events =
        turn_events
        |> Enum.filter(&(&1.type == "agent.custom_tool_use"))
        |> Map.new(fn event -> {event.id, event} end)

      context =
        turn_events
        |> Enum.reduce(Context.new([Context.user(prompt)]), fn turn_event, context ->
          append_custom_turn_event_to_context(turn_event, context, custom_tool_use_events)
        end)

      {:ok, context}
    end
  end

  defp load_custom_tool_turn_events(
         %Session{} = session,
         %SessionEvent{} = trigger_event,
         max_sequence,
         actor
       ) do
    SessionEvent
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(
      session_id == ^session.id and
        sequence >= ^trigger_event.sequence and
        sequence <= ^max_sequence
    )
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read()
    |> case do
      {:ok, events} ->
        agent_events =
          Enum.filter(events, fn turn_event ->
            turn_event.type in [
              "agent.tool_use",
              "agent.tool_result",
              "agent.mcp_tool_use",
              "agent.mcp_tool_result",
              "agent.custom_tool_use"
            ] and
              Map.get(stringify(turn_event.payload), "trigger_event_id") == trigger_event.id
          end)

        custom_tool_use_ids =
          agent_events
          |> Enum.filter(&(&1.type == "agent.custom_tool_use"))
          |> Enum.map(& &1.id)
          |> MapSet.new()

        custom_tool_result_events =
          Enum.filter(events, fn turn_event ->
            turn_event.type == "user.custom_tool_result" and
              MapSet.member?(custom_tool_use_ids, custom_tool_result_reference(turn_event))
          end)

        {:ok, Enum.sort_by(agent_events ++ custom_tool_result_events, & &1.sequence)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp append_custom_turn_event_to_context(
         %SessionEvent{type: "user.custom_tool_result"} = event,
         context,
         custom_tool_use_events
       ) do
    case Map.get(custom_tool_use_events, custom_tool_result_reference(event)) do
      %SessionEvent{} = custom_tool_use_event ->
        payload = stringify_payload(custom_tool_use_event)

        Context.append(
          context,
          Context.tool_result(
            payload["tool_use_id"],
            payload["tool_name"],
            custom_tool_result_output(event)
          )
        )

      nil ->
        context
    end
  end

  defp append_custom_turn_event_to_context(event, context, _custom_tool_use_events) do
    append_turn_event_to_context(event, context)
  end

  defp custom_tool_result_reference(%SessionEvent{} = event) do
    event
    |> stringify_payload()
    |> Map.get("custom_tool_use_id")
  end

  defp custom_tool_result_output(%SessionEvent{} = event) do
    content_text = extract_text_content(event.content)

    payload =
      event
      |> stringify_payload()
      |> Map.delete("custom_tool_use_id")

    cond do
      content_text != "" ->
        content_text

      event.content != [] ->
        Jason.encode!(stringify(event.content))

      map_size(payload) > 0 ->
        payload

      true ->
        ""
    end
  end

  defp build_tool_confirmation_activity(
         %Session{} = session,
         %SessionEvent{} = event,
         runtime_workspace,
         current_stop_reason,
         actor
       ) do
    with {:ok, confirmation} <- normalize_tool_confirmation_payload(event.payload),
         :ok <- ensure_tool_confirmation_pending(current_stop_reason, confirmation.tool_use_id),
         {:ok, %SessionEvent{} = tool_use_event} <-
           load_session_event(session.id, confirmation.tool_use_id, actor),
         :ok <- ensure_confirmation_tool_use_event(tool_use_event),
         {:ok, %SessionEvent{} = trigger_event} <-
           load_trigger_event(session.id, tool_use_event, actor),
         {:ok, context} <-
           rebuild_confirmation_context(session, trigger_event, tool_use_event, actor),
         {:ok, turn_result} <-
           continue_after_tool_confirmation(
             session,
             event,
             tool_use_event,
             trigger_event,
             context,
             runtime_workspace,
             confirmation
           ) do
      {:ok,
       %Activity{
         directives: turn_result.directives,
         runtime_workspace: turn_result.runtime_workspace,
         resume?: true,
         stop_reason_mode: turn_result.stop_reason_mode,
         current_stop_reason: :recompute
       }}
    else
      {:error, %{} = error} ->
        {:ok,
         error_activity(
           runtime_workspace,
           Map.merge(error, workspace_payload(runtime_workspace, event)),
           current_stop_reason
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp continue_after_tool_confirmation(
         %Session{} = session,
         _event,
         %SessionEvent{} = tool_use_event,
         %SessionEvent{} = trigger_event,
         %Context{} = context,
         runtime_workspace,
         confirmation
       ) do
    workspace_payload = resume_workspace_payload(tool_use_event, trigger_event)

    {:ok, result, updated_workspace} =
      confirmed_tool_result(session, runtime_workspace, tool_use_event, confirmation)

    result_directive =
      tool_result_directive(
        result,
        workspace_payload,
        mcp?: tool_use_event.type == "agent.mcp_tool_use"
      )

    next_context = append_tool_result(context, result)

    with {:ok, tool_runtime} <- resolve_tool_runtime(session) do
      {:ok,
       execute_tool_rounds(
         session,
         tool_runtime,
         next_context,
         updated_workspace,
         workspace_payload,
         [result_directive],
         %{provider: nil, model: nil, thinking: nil},
         1,
         []
       )}
    end
  end

  defp confirmed_tool_result(_session, runtime_workspace, %SessionEvent{} = tool_use_event, %{
         result: "allow"
       })
       when tool_use_event.type == "agent.tool_use" do
    tool_call = tool_call_from_use_event(tool_use_event)

    case RuntimeTools.execute(runtime_workspace, tool_call) do
      {:ok, result, updated_workspace} ->
        {:ok, result, updated_workspace}

      {:error, result, updated_workspace} ->
        {:ok, result, updated_workspace}
    end
  end

  defp confirmed_tool_result(
         %Session{} = session,
         runtime_workspace,
         %SessionEvent{} = tool_use_event,
         %{
           result: "allow"
         }
       ) do
    case RuntimeMCP.execute_use_event(session, tool_use_event.payload) do
      {:ok, result} ->
        {:ok, result, runtime_workspace}

      {:error, result} ->
        {:ok, result, runtime_workspace}
    end
  end

  defp confirmed_tool_result(
         _session,
         runtime_workspace,
         %SessionEvent{} = tool_use_event,
         confirmation
       ) do
    {:ok, denied_tool_result(tool_use_event, confirmation), runtime_workspace}
  end

  defp denied_tool_result(%SessionEvent{} = tool_use_event, confirmation) do
    payload = stringify(tool_use_event.payload)

    %{
      "tool_use_id" => payload["tool_use_id"],
      "tool_name" => payload["tool_name"],
      "input" => Map.get(payload, "input", %{}),
      "ok" => false,
      "error" => %{
        "error_type" => "permission_denied",
        "message" =>
          confirmation.deny_message || "Tool execution was denied by user confirmation."
      },
      "remote_tool_name" => Map.get(payload, "remote_tool_name"),
      "mcp_server_name" => Map.get(payload, "mcp_server_name"),
      "mcp_server_url" => Map.get(payload, "mcp_server_url")
    }
  end

  defp normalize_tool_confirmation_payload(payload) when is_map(payload) do
    payload = stringify(payload)

    with tool_use_id when is_binary(tool_use_id) and byte_size(tool_use_id) > 0 <-
           Map.get(payload, "tool_use_id"),
         result when result in ["allow", "deny"] <- Map.get(payload, "result") do
      {:ok,
       %{
         tool_use_id: tool_use_id,
         result: result,
         deny_message: Map.get(payload, "deny_message")
       }}
    else
      _other ->
        {:error,
         %{
           "error_type" => "invalid_tool_confirmation",
           "message" => "Tool confirmation payload must include tool_use_id and result."
         }}
    end
  end

  defp normalize_tool_confirmation_payload(_payload) do
    {:error,
     %{
       "error_type" => "invalid_tool_confirmation",
       "message" => "Tool confirmation payload must be an object."
     }}
  end

  defp ensure_tool_confirmation_pending(
         %{"type" => "requires_action", "event_ids" => event_ids},
         tool_use_id
       )
       when is_list(event_ids) do
    if tool_use_id in event_ids do
      :ok
    else
      {:error,
       %{
         "error_type" => "invalid_tool_confirmation",
         "message" => "Tool confirmation does not reference a pending approval request.",
         "tool_use_id" => tool_use_id
       }}
    end
  end

  defp ensure_tool_confirmation_pending(:recompute, tool_use_id) do
    {:error,
     %{
       "error_type" => "invalid_tool_confirmation",
       "message" => "Tool confirmation does not reference a pending approval request.",
       "tool_use_id" => tool_use_id
     }}
  end

  defp ensure_tool_confirmation_pending(_stop_reason, tool_use_id) do
    {:error,
     %{
       "error_type" => "invalid_tool_confirmation",
       "message" => "Session is not waiting on a tool confirmation.",
       "tool_use_id" => tool_use_id
     }}
  end

  defp ensure_confirmation_tool_use_event(%SessionEvent{type: type, payload: payload})
       when type in ["agent.tool_use", "agent.mcp_tool_use"] do
    if Map.get(stringify(payload), "awaiting_confirmation") do
      :ok
    else
      {:error,
       %{
         "error_type" => "invalid_tool_confirmation",
         "message" => "Tool confirmation does not reference a pending approval request."
       }}
    end
  end

  defp ensure_confirmation_tool_use_event(%SessionEvent{}) do
    {:error,
     %{
       "error_type" => "invalid_tool_confirmation",
       "message" =>
         "Tool confirmation must reference an agent.tool_use or agent.mcp_tool_use event."
     }}
  end

  defp rebuild_confirmation_context(session, trigger_event, tool_use_event, actor) do
    with {:ok, prompt} <- prompt_from_event(trigger_event),
         {:ok, turn_events} <- load_turn_events(session, trigger_event, tool_use_event, actor) do
      context =
        turn_events
        |> Enum.reduce(Context.new([Context.user(prompt)]), &append_turn_event_to_context/2)

      {:ok, context}
    end
  end

  defp load_turn_events(
         %Session{} = session,
         %SessionEvent{} = trigger_event,
         %SessionEvent{} = tool_use_event,
         actor
       ) do
    SessionEvent
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(
      session_id == ^session.id and
        sequence >= ^trigger_event.sequence and
        sequence <= ^tool_use_event.sequence
    )
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read()
    |> case do
      {:ok, events} ->
        {:ok,
         Enum.filter(events, fn event ->
           event.type in [
             "agent.tool_use",
             "agent.tool_result",
             "agent.mcp_tool_use",
             "agent.mcp_tool_result"
           ] and
             Map.get(stringify(event.payload), "trigger_event_id") == trigger_event.id
         end)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp append_turn_event_to_context(%SessionEvent{type: "agent.tool_use"} = event, context) do
    payload = stringify(event.payload)

    Context.append(
      context,
      Context.assistant(
        "",
        tool_calls: [
          %{
            "id" => payload["tool_use_id"],
            "name" => payload["tool_name"],
            "input" => Map.get(payload, "input", %{})
          }
        ]
      )
    )
  end

  defp append_turn_event_to_context(%SessionEvent{type: "agent.mcp_tool_use"} = event, context) do
    payload = stringify(event.payload)

    Context.append(
      context,
      Context.assistant(
        "",
        tool_calls: [
          %{
            "id" => payload["tool_use_id"],
            "name" => payload["tool_name"],
            "input" => Map.get(payload, "input", %{})
          }
        ]
      )
    )
  end

  defp append_turn_event_to_context(%SessionEvent{type: "agent.tool_result"} = event, context) do
    payload = stringify(event.payload)

    Context.append(
      context,
      Context.tool_result(
        payload["tool_use_id"],
        payload["tool_name"],
        tool_result_content_from_event_payload(payload)
      )
    )
  end

  defp append_turn_event_to_context(%SessionEvent{type: "agent.mcp_tool_result"} = event, context) do
    payload = stringify(event.payload)

    Context.append(
      context,
      Context.tool_result(
        payload["tool_use_id"],
        payload["tool_name"],
        tool_result_content_from_event_payload(payload)
      )
    )
  end

  defp append_turn_event_to_context(%SessionEvent{type: "agent.custom_tool_use"} = event, context) do
    payload = stringify(event.payload)

    Context.append(
      context,
      Context.assistant(
        "",
        tool_calls: [
          %{
            "id" => payload["tool_use_id"],
            "name" => payload["tool_name"],
            "input" => Map.get(payload, "input", %{})
          }
        ]
      )
    )
  end

  defp append_turn_event_to_context(_event, context), do: context

  defp tool_call_from_use_event(%SessionEvent{} = tool_use_event) do
    payload = stringify(tool_use_event.payload)

    %{
      "id" => payload["tool_use_id"],
      "name" => payload["tool_name"],
      "arguments" => Map.get(payload, "input", %{})
    }
  end

  defp load_trigger_event(session_id, %SessionEvent{} = tool_use_event, actor) do
    tool_use_event
    |> stringify_payload()
    |> Map.get("trigger_event_id")
    |> case do
      trigger_event_id when is_binary(trigger_event_id) ->
        load_session_event(session_id, trigger_event_id, actor)

      _other ->
        {:error,
         %{
           "error_type" => "invalid_tool_confirmation",
           "message" => "Blocked tool use is missing its triggering user message."
         }}
    end
  end

  defp load_session_event(session_id, event_id, actor) do
    SessionEvent
    |> Ash.Query.for_read(:by_id, %{id: event_id}, ash_opts(actor))
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.read_one()
    |> case do
      {:ok, %SessionEvent{} = event} ->
        {:ok, event}

      {:ok, nil} ->
        {:error,
         %{
           "error_type" => "invalid_tool_confirmation",
           "message" => "Tool confirmation references an unknown tool use event."
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resume_workspace_payload(%SessionEvent{} = tool_use_event, %SessionEvent{} = trigger_event) do
    tool_use_event
    |> stringify_payload()
    |> Map.take(["workspace_id", "workspace_backend"])
    |> Map.put("trigger_event_id", trigger_event.id)
    |> Map.put("trigger_sequence", trigger_event.sequence)
  end

  defp tool_result_content_from_event_payload(%{"ok" => true, "result" => result}) do
    RuntimeTools.tool_result_content(%{"ok" => true, "result" => result})
  end

  defp tool_result_content_from_event_payload(%{"ok" => false, "error" => error}) do
    RuntimeTools.tool_result_content(%{"ok" => false, "error" => error})
  end

  defp error_activity(runtime_workspace, error_payload, current_stop_reason) do
    %Activity{
      directives: [emit_signal("session.error", error_payload)],
      runtime_workspace: runtime_workspace,
      resume?: false,
      stop_reason_mode: :preserve,
      current_stop_reason: current_stop_reason
    }
  end

  defp error_turn(
         runtime_workspace,
         workspace_payload,
         error,
         provider,
         model,
         directives \\ [],
         thinking \\ nil
       ) do
    %{
      runtime_workspace: runtime_workspace,
      provider: provider,
      model: model,
      thinking: thinking || "Dispatching provider-backed inference.",
      stop_reason_mode: :recompute,
      directives:
        directives ++
          [
            emit_signal(
              "session.error",
              %{
                "phase" => "turn_error"
              }
              |> maybe_put("provider", provider)
              |> maybe_put("model", model)
              |> Map.merge(error)
              |> Map.merge(workspace_payload)
            )
          ]
    }
  end

  defp thinking_payload(turn_result, workspace_payload) do
    %{
      "content" => [
        %{
          "type" => "thinking",
          "thinking" => turn_result.thinking || "Dispatching provider-backed inference."
        }
      ],
      "phase" => "turn_start"
    }
    |> maybe_put("provider", turn_result.provider)
    |> maybe_put("model", turn_result.model)
    |> Map.merge(workspace_payload)
  end

  defp response_context(%{context: %Context{} = context}, _fallback), do: context
  defp response_context(_response, fallback), do: fallback

  defp normalize_response_text(text) when is_binary(text) do
    if String.trim(text) == "" do
      "Provider-backed inference completed without text output."
    else
      text
    end
  end

  defp normalize_response_text(_text),
    do: "Provider-backed inference completed without text output."

  defp normalize_thinking_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_thinking_text(_text), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    usage
    |> stringify()
    |> Map.take([
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "cached_tokens",
      "reasoning_tokens"
    ])
  end

  defp normalize_usage(_usage), do: %{}

  defp resolve_stop_reason(%Activity{current_stop_reason: :recompute}, emitted_events) do
    stop_reason_from_emitted_events(emitted_events)
  end

  defp resolve_stop_reason(%Activity{stop_reason_mode: :recompute}, emitted_events) do
    stop_reason_from_emitted_events(emitted_events)
  end

  defp resolve_stop_reason(%Activity{current_stop_reason: current_stop_reason}, _emitted_events) do
    normalize_runtime_stop_reason(current_stop_reason)
  end

  defp stop_reason_from_emitted_events(emitted_events) do
    event_ids =
      emitted_events
      |> Enum.filter(fn event ->
        case event.type do
          "agent.custom_tool_use" ->
            true

          "agent.tool_use" ->
            Map.get(stringify(event.payload), "awaiting_confirmation")

          "agent.mcp_tool_use" ->
            Map.get(stringify(event.payload), "awaiting_confirmation")

          _other ->
            false
        end
      end)
      |> Enum.map(& &1.id)

    case event_ids do
      [] -> nil
      _event_ids -> %{"type" => "requires_action", "event_ids" => event_ids}
    end
  end

  defp normalize_runtime_stop_reason(nil), do: nil
  defp normalize_runtime_stop_reason(:recompute), do: :recompute
  defp normalize_runtime_stop_reason(stop_reason), do: stringify(stop_reason)

  defp tool_permission_policy(%Session{} = session, mcp_tools, tool_name) do
    case Map.get(mcp_tools, tool_name) do
      nil -> RuntimeTools.permission_policy(session.agent_version, tool_name)
      tool_entry -> RuntimeMCP.permission_policy(tool_entry)
    end
  end

  defp resolve_tool_runtime(%Session{} = session, opts \\ []) do
    builtin_and_custom = RuntimeTools.tool_definitions(session.agent_version)
    delegate_tools = callable_agent_tools(session, opts)

    with {:ok, mcp_tools} <- RuntimeMCP.discover_tools(session) do
      {:ok,
       %{
         definitions:
           builtin_and_custom ++
             Enum.map(mcp_tools, & &1.tool) ++
             Enum.map(delegate_tools, fn {_name, entry} -> entry.tool end),
         mcp_tools: Map.new(mcp_tools, &{&1.local_name, &1}),
         delegate_tools:
           Map.new(delegate_tools, fn {name, entry} -> {name, Map.delete(entry, :tool)} end)
       }}
    end
  end

  defp callable_agent_tools(%Session{} = session, opts) do
    if Keyword.get(opts, :allow_delegate_tools?, true) do
      session
      |> callable_agent_links()
      |> Enum.reduce(%{}, fn link, acc ->
        case callable_agent_tool(link) do
          nil -> acc
          {tool_name, entry} -> Map.put(acc, tool_name, entry)
        end
      end)
    else
      %{}
    end
  end

  defp callable_agent_links(%Session{
         agent_version: %AgentVersion{agent_version_callable_agents: %NotLoaded{}}
       }),
       do: []

  defp callable_agent_links(%Session{
         agent_version: %AgentVersion{agent_version_callable_agents: callable_agent_links}
       })
       when is_list(callable_agent_links),
       do: callable_agent_links

  defp callable_agent_links(%Session{}), do: []

  defp callable_agent_tool(%{callable_agent_id: agent_id} = link) when is_binary(agent_id) do
    callable_agent_name =
      case Map.get(link, :callable_agent) do
        %Agent{name: name} when is_binary(name) and name != "" -> name
        _other -> agent_id
      end

    tool_name = callable_agent_tool_name(agent_id)

    {tool_name,
     %{
       tool: delegate_tool_definition(tool_name, callable_agent_name),
       callable_agent_id: agent_id,
       callable_agent_name: callable_agent_name,
       callable_agent_version_id: Map.get(link, :callable_agent_version_id)
     }}
  end

  defp callable_agent_tool(_link), do: nil

  defp mcp_tool_entry(%{mcp_tools: mcp_tools}, tool_name) when is_map(mcp_tools) do
    Map.get(mcp_tools, tool_name)
  end

  defp mcp_tool_entry(_tool_runtime, _tool_name), do: nil

  defp delegate_tool_entry(%{delegate_tools: delegate_tools}, tool_name)
       when is_map(delegate_tools) do
    Map.get(delegate_tools, tool_name)
  end

  defp delegate_tool_entry(_tool_runtime, _tool_name), do: nil

  defp execute_runtime_tool(session, mcp_tools, runtime_workspace, tool_call) do
    case Map.get(mcp_tools, tool_call.name) do
      nil ->
        RuntimeTools.execute(runtime_workspace, tool_call)

      entry ->
        case RuntimeMCP.execute(session, tool_call, entry) do
          {:ok, result} -> {:ok, result, runtime_workspace}
          {:error, result} -> {:error, result, runtime_workspace}
        end
    end
  end

  defp execute_delegate_tool_call(
         %Session{} = session,
         delegate_tool,
         normalized_tool_call,
         runtime_workspace,
         directives,
         opts
       ) do
    actor = Keyword.get(opts, :actor)

    with {:ok, %SessionThread{} = current_thread} <- resolve_current_thread(session, actor, opts),
         {:ok, message} <- delegate_message(normalized_tool_call.arguments),
         {:ok, %AgentVersion{} = delegate_version} <-
           resolve_callable_agent_version(delegate_tool, actor),
         {:ok, {delegate_thread, created?}} <-
           SessionThreads.ensure_delegate_thread(session, current_thread, delegate_version, actor),
         {:ok, %SessionThread{} = running_thread} <-
           SessionThreads.update_status(delegate_thread, :running, nil, actor) do
      leading_directives =
        directives ++
          delegate_thread_created_directives(
            created?,
            current_thread,
            running_thread,
            delegate_version
          ) ++
          [
            thread_message_sent_directive(
              current_thread.id,
              running_thread.id,
              normalized_tool_call.id,
              normalized_tool_call.name,
              message,
              delegate_tool.callable_agent_id,
              :both
            ),
            thread_message_received_directive(
              running_thread.id,
              current_thread.id,
              normalized_tool_call.id,
              normalized_tool_call.name,
              message,
              delegate_tool.callable_agent_id,
              :thread
            )
          ]

      case run_delegate_thread_turn(
             session,
             current_thread,
             running_thread,
             delegate_version,
             normalized_tool_call,
             message,
             runtime_workspace,
             actor
           ) do
        {:ok, delegate_turn} ->
          with {:ok, %SessionThread{} = idle_thread} <-
                 SessionThreads.update_status(
                   running_thread,
                   :idle,
                   normalize_runtime_stop_reason(delegate_turn.stop_reason),
                   actor
                 ) do
            updated_directives =
              leading_directives ++
                delegate_turn.directives ++
                [
                  thread_message_sent_directive(
                    idle_thread.id,
                    current_thread.id,
                    normalized_tool_call.id,
                    normalized_tool_call.name,
                    delegate_turn.reply_text,
                    delegate_tool.callable_agent_id,
                    :thread
                  ),
                  thread_message_received_directive(
                    current_thread.id,
                    idle_thread.id,
                    normalized_tool_call.id,
                    normalized_tool_call.name,
                    delegate_turn.reply_text,
                    delegate_tool.callable_agent_id,
                    :both
                  ),
                  thread_idle_directive(
                    current_thread.id,
                    idle_thread.id,
                    delegate_turn.stop_reason
                  )
                ]

            result =
              delegate_tool_result(
                normalized_tool_call,
                idle_thread,
                delegate_version,
                delegate_turn.reply_text,
                delegate_turn.stop_reason
              )

            {:ok, result, delegate_turn.runtime_workspace, updated_directives}
          end

        {:error, delegate_turn} ->
          with {:ok, %SessionThread{} = idle_thread} <-
                 SessionThreads.update_status(
                   running_thread,
                   :idle,
                   normalize_runtime_stop_reason(delegate_turn.stop_reason),
                   actor
                 ) do
            updated_directives =
              leading_directives ++
                delegate_turn.directives ++
                [
                  thread_idle_directive(
                    current_thread.id,
                    idle_thread.id,
                    delegate_turn.stop_reason
                  )
                ]

            {:error, delegate_turn.error, delegate_turn.runtime_workspace, updated_directives}
          end
      end
    else
      {:error, %{} = error} ->
        {:error, error, runtime_workspace, directives}

      {:error, error} ->
        {:error, normalize_delegate_error(error), runtime_workspace, directives}
    end
  end

  defp run_delegate_thread_turn(
         %Session{} = session,
         %SessionThread{} = parent_thread,
         %SessionThread{} = delegate_thread,
         %AgentVersion{} = delegate_version,
         normalized_tool_call,
         message,
         runtime_workspace,
         actor
       ) do
    delegate_session = delegate_session(session, delegate_version)

    received_event =
      struct!(SessionEvent, %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        session_thread_id: delegate_thread.id,
        sequence: -1,
        type: "agent.thread_message_received",
        content: [%{"type" => "text", "text" => message}],
        payload: %{
          "from_thread_id" => parent_thread.id,
          "tool_use_id" => normalized_tool_call.id,
          "tool_name" => normalized_tool_call.name,
          "callable_agent_id" => delegate_version.agent_id
        }
      })

    workspace_payload = workspace_payload(runtime_workspace, received_event)

    turn_result =
      build_user_message_turn(
        delegate_session,
        received_event,
        runtime_workspace,
        workspace_payload,
        actor: actor,
        allow_delegate_tools?: false,
        current_thread: delegate_thread,
        current_thread_role: :delegate
      )

    scoped_directives =
      [
        emit_signal("agent.thinking", thinking_payload(turn_result, workspace_payload))
        | turn_result.directives
      ]
      |> Enum.map(&scope_directive(&1, delegate_thread.id, @delegate_stream_scope))

    stop_reason = stop_reason_from_directives(scoped_directives)

    case delegate_reply_text(scoped_directives) do
      {:ok, reply_text} ->
        {:ok,
         %{
           directives: scoped_directives,
           runtime_workspace: turn_result.runtime_workspace,
           reply_text: reply_text,
           stop_reason: stop_reason
         }}

      {:error, error} ->
        delegate_error = delegate_error_payload(scoped_directives) || error

        {:error,
         %{
           error: Map.put(delegate_error, "stop_reason", stop_reason),
           directives: scoped_directives,
           runtime_workspace: turn_result.runtime_workspace,
           stop_reason: stop_reason
         }}
    end
  end

  defp resolve_current_thread(%Session{} = session, actor, opts) do
    case Keyword.get(opts, :current_thread) do
      %SessionThread{} = thread -> {:ok, thread}
      _other -> SessionThreads.ensure_primary_thread(session, actor)
    end
  end

  defp resolve_callable_agent_version(%{callable_agent_version_id: version_id}, actor)
       when is_binary(version_id) do
    load_agent_version_runtime_graph(version_id, actor)
  end

  defp resolve_callable_agent_version(%{callable_agent_id: agent_id}, actor)
       when is_binary(agent_id) do
    load_latest_callable_version(agent_id, actor)
  end

  defp resolve_callable_agent_version(_delegate_tool, _actor) do
    {:error,
     %{
       "error_type" => "delegate_not_found",
       "message" => "Callable agent resolution requires a persisted agent reference."
     }}
  end

  defp load_latest_callable_version(agent_id, actor) do
    Agent
    |> Ash.Query.for_read(:by_id, %{id: agent_id}, agent_opts(actor))
    |> Ash.Query.load(:latest_version)
    |> Ash.read_one()
    |> case do
      {:ok, %Agent{latest_version: %AgentVersion{id: version_id}}} ->
        load_agent_version_runtime_graph(version_id, actor)

      {:ok, %Agent{latest_version: nil}} ->
        {:error,
         %{
           "error_type" => "delegate_not_found",
           "message" => "Callable agent #{agent_id} does not have an available version."
         }}

      {:ok, nil} ->
        {:error,
         %{
           "error_type" => "delegate_not_found",
           "message" => "Callable agent #{agent_id} was not found."
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_agent_version_runtime_graph(version_id, actor) do
    AgentVersion
    |> Ash.Query.for_read(:by_id, %{id: version_id}, agent_opts(actor))
    |> Ash.Query.load(
      agent_version_skills: [:skill_version, skill: [:latest_version]],
      agent_version_callable_agents: [:callable_agent, :callable_agent_version]
    )
    |> Ash.read_one()
    |> case do
      {:ok, %AgentVersion{} = version} ->
        {:ok, version}

      {:ok, nil} ->
        {:error,
         %{
           "error_type" => "delegate_not_found",
           "message" => "Callable agent version #{version_id} was not found."
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp delegate_session(%Session{} = session, %AgentVersion{} = delegate_version) do
    %Session{
      session
      | agent_id: delegate_version.agent_id,
        agent_version_id: delegate_version.id,
        agent_version: delegate_version
    }
  end

  defp delegate_thread_created_directives(
         false,
         _current_thread,
         _delegate_thread,
         _delegate_version
       ),
       do: []

  defp delegate_thread_created_directives(
         true,
         %SessionThread{} = current_thread,
         %SessionThread{} = delegate_thread,
         %AgentVersion{} = delegate_version
       ) do
    [
      scoped_signal(
        "session.thread_created",
        %{
          "session_thread_id" => delegate_thread.id,
          "parent_thread_id" => current_thread.id,
          "agent_id" => delegate_thread.agent_id,
          "agent_version" => delegate_version.version,
          "model" => stringify(delegate_version.model)
        },
        current_thread.id,
        @session_stream_scope
      )
    ]
  end

  defp thread_message_sent_directive(
         from_thread_id,
         to_thread_id,
         tool_use_id,
         tool_name,
         message,
         callable_agent_id,
         stream_scope
       ) do
    scoped_signal(
      "agent.thread_message_sent",
      %{
        "content" => [%{"type" => "text", "text" => message}],
        "from_thread_id" => from_thread_id,
        "to_thread_id" => to_thread_id,
        "tool_use_id" => tool_use_id,
        "tool_name" => tool_name,
        "callable_agent_id" => callable_agent_id
      },
      from_thread_id,
      stream_scope
    )
  end

  defp thread_message_received_directive(
         thread_id,
         from_thread_id,
         tool_use_id,
         tool_name,
         message,
         callable_agent_id,
         stream_scope
       ) do
    scoped_signal(
      "agent.thread_message_received",
      %{
        "content" => [%{"type" => "text", "text" => message}],
        "from_thread_id" => from_thread_id,
        "tool_use_id" => tool_use_id,
        "tool_name" => tool_name,
        "callable_agent_id" => callable_agent_id
      },
      thread_id,
      stream_scope
    )
  end

  defp thread_idle_directive(thread_id, delegate_thread_id, stop_reason) do
    scoped_signal(
      "session.thread_idle",
      %{
        "session_thread_id" => delegate_thread_id,
        "status" => "idle"
      }
      |> maybe_put("stop_reason", normalize_runtime_stop_reason(stop_reason)),
      thread_id,
      @session_stream_scope
    )
  end

  defp delegate_tool_result(
         normalized_tool_call,
         %SessionThread{} = thread,
         %AgentVersion{} = delegate_version,
         reply_text,
         stop_reason
       ) do
    %{
      "tool_use_id" => normalized_tool_call.id,
      "tool_name" => normalized_tool_call.name,
      "input" => stringify(normalized_tool_call.arguments),
      "ok" => true,
      "result" => %{
        "session_thread_id" => thread.id,
        "agent_id" => thread.agent_id,
        "agent_version" => delegate_version.version,
        "message" => reply_text,
        "stop_reason" => normalize_runtime_stop_reason(stop_reason)
      }
    }
  end

  defp nested_delegation?(opts) do
    case Keyword.get(opts, :current_thread_role) do
      :delegate -> true
      _other -> false
    end
  end

  defp nested_delegation_error(tool_name) do
    %{
      "error_type" => "nested_delegation_not_allowed",
      "message" => "Delegate threads cannot invoke callable agents.",
      "tool_name" => tool_name
    }
  end

  defp delegate_message(arguments) when is_map(arguments) do
    case Map.get(stringify(arguments), "message") do
      message when is_binary(message) ->
        case String.trim(message) do
          "" -> invalid_delegate_input()
          _trimmed -> {:ok, message}
        end

      _other ->
        invalid_delegate_input()
    end
  end

  defp delegate_message(_arguments), do: invalid_delegate_input()

  defp invalid_delegate_input do
    {:error,
     %{
       "error_type" => "invalid_delegate_input",
       "message" => "Callable agent delegation requires a non-empty message."
     }}
  end

  defp delegate_reply_text(directives) when is_list(directives) do
    directives
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Directive.Emit{signal: %{type: "agent.message", data: data}} ->
        data
        |> Map.get("content", [])
        |> extract_text_content()
        |> case do
          "" -> nil
          text -> {:ok, text}
        end

      _directive ->
        nil
    end)
    |> case do
      {:ok, text} ->
        {:ok, text}

      nil ->
        {:error,
         %{
           "error_type" => "delegate_incomplete",
           "message" => "Delegate thread did not produce a final message."
         }}
    end
  end

  defp delegate_error_payload(directives) when is_list(directives) do
    Enum.find_value(Enum.reverse(directives), fn
      %Directive.Emit{signal: %{type: "session.error", data: data}} ->
        data
        |> stringify()
        |> Map.drop(["_session_thread_id", "_stream_scope"])

      _directive ->
        nil
    end)
  end

  defp stop_reason_from_directives(directives) when is_list(directives) do
    event_ids =
      directives
      |> Enum.filter(fn
        %Directive.Emit{signal: %{type: "agent.custom_tool_use"}} ->
          true

        %Directive.Emit{signal: %{type: "agent.tool_use", data: data}} ->
          Map.get(data, "awaiting_confirmation")

        %Directive.Emit{signal: %{type: "agent.mcp_tool_use", data: data}} ->
          Map.get(data, "awaiting_confirmation")

        _directive ->
          false
      end)
      |> Enum.map(fn
        %Directive.Emit{signal: %{id: id}} -> id
        _directive -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case event_ids do
      [] -> nil
      ids -> %{"type" => "requires_action", "event_ids" => ids}
    end
  end

  defp stop_reason_from_directives(_directives), do: nil

  defp delegate_tool_definition(tool_name, callable_agent_name) do
    Tool.new!(
      name: tool_name,
      description: "Delegate work to #{callable_agent_name} inside the current session.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "Task or prompt to send to the callable agent."
          }
        },
        "required" => ["message"]
      },
      callback: {RuntimeTools, :noop_tool_callback}
    )
  end

  defp callable_agent_tool_name(agent_id), do: @delegate_tool_prefix <> agent_id

  defp delegate_tool_call?(tool_name) when is_binary(tool_name),
    do: String.starts_with?(tool_name, @delegate_tool_prefix)

  defp delegate_tool_call?(_tool_name), do: false

  defp normalize_delegate_error(%{} = error), do: stringify(error)

  defp normalize_delegate_error(error),
    do: %{"error_type" => "delegate_error", "message" => inspect(error)}

  defp agent_opts(nil), do: [domain: JidoManagedAgents.Agents, authorize?: false]
  defp agent_opts(actor), do: [actor: actor, domain: JidoManagedAgents.Agents]

  defp custom_tool_enabled?(%Session{agent_version: %{tools: tools}}, tool_name)
       when is_list(tools) and is_binary(tool_name) do
    Enum.any?(tools, fn declaration ->
      Map.get(declaration, "type") == "custom" and Map.get(declaration, "name") == tool_name
    end)
  end

  defp custom_tool_enabled?(%Session{}, _tool_name), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_payload(%SessionEvent{} = event), do: stringify(event.payload)

  defp prompt_from_event(%SessionEvent{} = event) do
    case extract_text_content(event.content) do
      "" ->
        {:error,
         %{
           "error_type" => "validation",
           "message" =>
             "user.message content must include at least one text block for provider-backed inference."
         }}

      text ->
        {:ok, text}
    end
  end

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_part/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp extract_text_content(_content), do: ""

  defp extract_text_part(%{"text" => text}) when is_binary(text), do: text
  defp extract_text_part(%{text: text}) when is_binary(text), do: text
  defp extract_text_part(_content_part), do: nil

  defp emit_signal(type, payload) when is_binary(type) and is_map(payload) do
    payload =
      payload
      |> stringify()
      |> Map.put_new("content", [])

    type
    |> Jido.Signal.new!(payload, source: @runtime_source)
    |> Directive.emit()
  end

  defp scoped_signal(type, payload, thread_id, stream_scope) do
    emit_signal(type, scope_data(payload, thread_id, stream_scope))
  end

  defp scope_directive(%Directive.Emit{signal: signal}, thread_id, stream_scope) do
    scoped_data = scope_data(Map.get(signal, :data, %{}), thread_id, stream_scope)
    emit_signal(signal.type, scoped_data)
  end

  defp scope_directive(directive, _thread_id, _stream_scope), do: directive

  defp scope_data(payload, thread_id, stream_scope) do
    payload
    |> stringify()
    |> maybe_put("_session_thread_id", thread_id)
    |> maybe_put("_stream_scope", stream_scope_value(stream_scope))
  end

  defp workspace_payload(runtime_workspace, event) do
    workspace = RuntimeWorkspace.persisted_workspace(runtime_workspace)

    %{
      "workspace_id" => RuntimeWorkspace.workspace_id(runtime_workspace),
      "workspace_backend" => workspace.backend |> to_string(),
      "trigger_event_id" => event.id,
      "trigger_sequence" => event.sequence
    }
  end

  defp persist_directive(
         %Session{} = session,
         %Directive.Emit{signal: signal},
         sequence,
         processed_at,
         actor,
         default_thread_id,
         default_stream_scope
       ) do
    attrs =
      signal_event_attrs(signal, sequence, processed_at, default_thread_id, default_stream_scope)

    SessionEvent
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, session.user_id)
      |> Map.put(:session_id, session.id),
      ash_opts(actor)
    )
    |> Ash.create()
  end

  defp persist_directive(
         _session,
         directive,
         _sequence,
         _processed_at,
         _actor,
         _default_thread_id,
         _default_stream_scope
       ) do
    {:error, {:unsupported_runtime_directive, directive}}
  end

  defp signal_event_attrs(signal, sequence, processed_at, default_thread_id, default_stream_scope) do
    data =
      signal
      |> Map.get(:data, %{})
      |> stringify()

    {content, data} = Map.pop(data, "content", [])
    {session_thread_id, data} = pop_thread_id(data, default_thread_id)
    {stream_scope, data} = pop_stream_scope(data, default_stream_scope)
    {stop_reason, payload} = Map.pop(data, "stop_reason", nil)

    %{
      session_thread_id: normalize_session_thread_id(session_thread_id),
      sequence: sequence,
      type: signal.type,
      content: normalize_content(content),
      payload: normalize_payload(payload),
      processed_at: processed_at,
      stop_reason: normalize_stop_reason(stop_reason),
      metadata: %{
        "jido_signal" => signal_metadata(signal),
        "stream_scope" => stream_scope_value(stream_scope)
      }
    }
  end

  defp pop_thread_id(data, default_thread_id) do
    data
    |> Map.pop("_session_thread_id")
    |> case do
      {nil, data} -> Map.pop(data, "session_thread_id", default_thread_id)
      result -> result
    end
  end

  defp pop_stream_scope(data, default_stream_scope) do
    data
    |> Map.pop("_stream_scope")
    |> case do
      {nil, data} -> Map.pop(data, "stream_scope", default_stream_scope)
      result -> result
    end
  end

  defp normalize_session_thread_id(value) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp normalize_session_thread_id(_value), do: nil

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, &stringify/1)
  end

  defp normalize_content(_content), do: []

  defp normalize_payload(payload) when is_map(payload), do: stringify(payload)
  defp normalize_payload(_payload), do: %{}

  defp normalize_stop_reason(stop_reason) when is_map(stop_reason), do: stringify(stop_reason)
  defp normalize_stop_reason(_stop_reason), do: nil

  defp stream_scope_value(:thread), do: "thread"
  defp stream_scope_value("thread"), do: "thread"
  defp stream_scope_value(_stream_scope), do: "both"

  defp signal_metadata(signal) do
    %{
      "id" => signal.id,
      "source" => signal.source,
      "subject" => signal.subject,
      "time" => signal.time,
      "specversion" => signal.specversion,
      "extensions" => stringify(Map.get(signal, :extensions, %{}))
    }
  end

  defp mark_events_processed(session_id, pending_events) do
    processed_at = DateTime.utc_now()
    sequences = Enum.map(pending_events, & &1.sequence)

    Repo.query!(
      """
      UPDATE session_events
      SET processed_at = $3
      WHERE session_id = $1 AND sequence = ANY($2::integer[])
      """,
      [dump_uuid!(session_id), sequences, processed_at]
    )

    :ok
  end

  defp lock_session(session_id) do
    Repo.query!(
      "SELECT id FROM sessions WHERE id = $1 FOR UPDATE",
      [dump_uuid!(session_id)]
    )

    :ok
  end

  defp next_sequence(session_id) do
    %Postgrex.Result{rows: [[sequence]]} =
      Repo.query!(
        "SELECT COALESCE(MAX(sequence) + 1, 0) FROM session_events WHERE session_id = $1",
        [dump_uuid!(session_id)]
      )

    sequence
  end

  defp ash_opts(nil), do: [authorize?: false, domain: Sessions]
  defp ash_opts(actor), do: [actor: actor, domain: Sessions]

  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
