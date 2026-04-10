defmodule JidoManagedAgents.Agents.AgentCatalog do
  @moduledoc """
  Shared create, update, archive, and lookup operations for persisted agents.

  Both the `/v1` API and the dashboard builder use this module so the browser
  flow stays aligned with the public contract and versioning semantics.
  """

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
  alias JidoManagedAgents.Agents.AgentDefinition
  alias JidoManagedAgents.Agents.AgentLifecycle
  alias JidoManagedAgents.Agents.AgentModel
  alias JidoManagedAgents.Agents.AgentVersion
  alias JidoManagedAgents.Agents.AgentVersionCallableAgent
  alias JidoManagedAgents.Agents.AgentVersionSkill
  alias JidoManagedAgents.Agents.SkillReference
  alias JidoManagedAgents.Agents.ToolDeclaration

  @version_load [
    agent_version_skills: [:skill, :skill_version],
    agent_version_callable_agents: [:callable_agent, :callable_agent_version]
  ]

  @latest_version_load [latest_version: @version_load]

  @spec version_load() :: keyword()
  def version_load, do: @version_load

  @spec latest_version_load() :: keyword()
  def latest_version_load, do: @latest_version_load

  @spec fetch_agent(String.t(), struct(), list()) ::
          {:ok, Agent.t()} | {:error, :not_found | term()}
  def fetch_agent(id, actor, load \\ @latest_version_load) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(actor))
      |> maybe_load(load)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Agent{} = agent} -> {:ok, agent}
      {:error, error} -> {:error, error}
    end
  end

  @spec list_versions(Agent.t(), struct()) :: {:ok, [AgentVersion.t()]} | {:error, term()}
  def list_versions(%Agent{} = agent, actor) do
    AgentVersion
    |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
    |> Ash.Query.filter(agent_id == ^agent.id)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.load(@version_load)
    |> Ash.read()
  end

  @spec create_from_params(map(), struct()) :: {:ok, Agent.t()} | {:error, term()}
  def create_from_params(params, actor) when is_map(params) do
    with {:ok, payload} <- AgentDefinition.normalize_create_payload(params, actor: actor) do
      create_agent(payload, actor)
    end
  end

  @spec update_from_params(Agent.t(), map(), struct()) :: {:ok, Agent.t()} | {:error, term()}
  def update_from_params(%Agent{} = agent, params, actor) when is_map(params) do
    with :ok <- ensure_not_archived(agent),
         {:ok, payload} <- normalize_update_payload(params, agent, actor),
         :ok <- ensure_current_version(agent, payload.current_version) do
      if payload.noop? do
        {:ok, agent}
      else
        update_agent(agent, payload, actor)
      end
    end
  end

  @spec archive(Agent.t(), struct()) :: {:ok, Agent.t()} | {:error, term()}
  def archive(%Agent{archived_at: %DateTime{}} = agent, _actor), do: {:ok, agent}

  def archive(%Agent{} = agent, actor) do
    with {:ok, %Agent{} = archived_agent} <-
           agent
           |> Ash.Changeset.for_update(:archive, %{}, ash_opts(actor))
           |> Ash.update() do
      load_agent(archived_agent.id, actor)
    end
  end

  @spec destroy(Agent.t(), struct()) :: :ok | {:error, term()}
  def destroy(%Agent{} = agent, actor) do
    with :ok <- ensure_delete_allowed(agent) do
      case agent
           |> Ash.Changeset.for_destroy(:destroy, %{}, ash_opts(actor))
           |> Ash.destroy() do
        :ok -> :ok
        {:ok, _destroyed_agent} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  @spec ash_opts(struct()) :: keyword()
  def ash_opts(actor), do: [actor: actor, domain: Agents]

  defp create_agent(%{agent: agent_attrs, version: version_attrs}, actor) do
    opts = ash_opts(actor)
    resources = [Agent, AgentVersion, AgentVersionSkill, AgentVersionCallableAgent]

    Ash.transact(resources, fn ->
      with {:ok, %Agent{} = agent} <- create_agent_record(agent_attrs, opts),
           {:ok, _version} <- create_initial_version(agent, version_attrs, opts),
           {:ok, %Agent{} = loaded_agent} <- load_agent(agent.id, actor) do
        loaded_agent
      end
    end)
  end

  defp update_agent(%Agent{} = agent, %{agent: agent_attrs, version: version_attrs}, actor) do
    opts = ash_opts(actor)
    resources = [Agent, AgentVersion, AgentVersionSkill, AgentVersionCallableAgent]

    Ash.transact(resources, fn ->
      with {:ok, _agent} <- sync_agent_record(agent, agent_attrs, opts),
           {:ok, _version} <- create_next_version(agent, version_attrs, opts),
           {:ok, %Agent{} = loaded_agent} <- load_agent(agent.id, actor) do
        loaded_agent
      end
    end)
  end

  defp load_agent(agent_id, actor) do
    fetch_agent(agent_id, actor, @latest_version_load)
  end

  defp create_agent_record(attrs, opts) do
    Agent
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, Keyword.fetch!(opts, :actor).id),
      opts
    )
    |> Ash.create()
  end

  defp create_initial_version(agent, attrs, opts) do
    AgentVersion
    |> Ash.Changeset.for_create(
      :create,
      attrs
      |> Map.put(:user_id, agent.user_id)
      |> Map.put(:agent_id, agent.id)
      |> Map.put(:version, 1),
      opts
    )
    |> Ash.create()
  end

  defp create_next_version(agent, attrs, opts) do
    AgentVersion
    |> Ash.Changeset.for_create(
      :create,
      attrs
      |> Map.put(:user_id, agent.user_id)
      |> Map.put(:agent_id, agent.id)
      |> Map.put(:version, agent.latest_version.version + 1),
      opts
    )
    |> Ash.create()
  end

  defp sync_agent_record(agent, attrs, opts) do
    if agent_requires_sync?(agent, attrs) do
      agent
      |> Ash.Changeset.for_update(:update, attrs, opts)
      |> Ash.update()
    else
      {:ok, agent}
    end
  end

  defp normalize_update_payload(
         params,
         %Agent{latest_version: %AgentVersion{} = latest_version} = agent,
         actor
       )
       when is_map(params) do
    params = stringify_top_level_keys(params)
    owner_id = agent.user_id
    current_skills = version_skill_links(latest_version, owner_id)
    current_callable_agents = version_callable_agent_links(latest_version, owner_id)

    with {:ok, current_version} <- required_positive_integer(params, "version"),
         {:ok, name} <- merge_required_string(params, "name", latest_version.name),
         {:ok, model} <- merge_model(params, latest_version.model),
         {:ok, system} <- merge_optional_string(params, "system", latest_version.system),
         {:ok, description} <-
           merge_optional_string(params, "description", latest_version.description),
         {:ok, metadata} <- merge_metadata(params, latest_version.metadata),
         {:ok, tools} <- merge_tool_declarations(params, latest_version.tools),
         {:ok, mcp_servers} <-
           merge_array_of_maps(params, "mcp_servers", latest_version.mcp_servers),
         {:ok, skills} <- merge_skill_links(params, current_skills, actor, owner_id),
         {:ok, callable_agents} <-
           merge_callable_agent_links(params, current_callable_agents, actor, owner_id) do
      version_attrs = %{
        name: name,
        description: description,
        model: model,
        system: system,
        tools: tools,
        mcp_servers: mcp_servers,
        metadata: metadata,
        agent_version_skills: skills,
        agent_version_callable_agents: callable_agents
      }

      {:ok,
       %{
         current_version: current_version,
         agent: %{
           name: name,
           description: description,
           metadata: metadata
         },
         version: version_attrs,
         noop?: version_attrs == version_contents(latest_version, owner_id)
       }}
    end
  end

  defp normalize_update_payload(_params, _agent, _actor) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  defp ensure_current_version(%Agent{latest_version: %AgentVersion{version: version}}, version),
    do: :ok

  defp ensure_current_version(%Agent{}, _version) do
    {:error, {:conflict, "The supplied version does not match the current agent version."}}
  end

  defp ensure_not_archived(%Agent{archived_at: nil}), do: :ok

  defp ensure_not_archived(%Agent{}) do
    {:error, {:invalid_request, "Archived agents are read-only."}}
  end

  defp ensure_delete_allowed(%Agent{} = agent) do
    with {:ok, blockers} <- AgentLifecycle.delete_blockers(agent.id) do
      case AgentLifecycle.delete_conflict_message(blockers) do
        nil -> :ok
        message -> {:error, {:conflict, message}}
      end
    end
  end

  defp normalize_model(nil), do: {:error, {:invalid_request, "model is required."}}
  defp normalize_model(model), do: AgentModel.normalize(model)

  defp normalize_skill_links(nil, _actor, opts), do: {:ok, Keyword.fetch!(opts, :default)}

  defp normalize_skill_links(skills, actor, opts) do
    SkillReference.normalize_many(
      skills,
      opts
      |> Keyword.put(:actor, actor)
      |> Keyword.put_new(:default, [])
    )
  end

  defp normalize_callable_agent_links(nil, _actor, opts),
    do: {:ok, Keyword.fetch!(opts, :default)}

  defp normalize_callable_agent_links(callable_agents, actor, opts)
       when is_list(callable_agents) do
    callable_agents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {callable_agent, index}, {:ok, acc} ->
      case normalize_callable_agent_link(callable_agent, index, actor, opts) do
        {:ok, normalized_callable_agent} ->
          {:cont, {:ok, acc ++ [normalized_callable_agent]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_callable_agent_links(_callable_agents, _actor, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp normalize_callable_agent_link(callable_agent, index, actor, opts)
       when is_map(callable_agent) do
    callable_agent = stringify_top_level_keys(callable_agent)
    user_id = Keyword.get(opts, :user_id, actor.id)

    with {:ok, callable_agent_id} <-
           required_string(
             %{"id" => callable_agent["id"]},
             "id",
             prefix: field_prefix(opts, index)
           ),
         {:ok, version} <-
           optional_integer(callable_agent["version"], "#{field_prefix(opts, index)}version"),
         {:ok, metadata} <-
           map_value(
             callable_agent["metadata"],
             default: %{},
             field: "#{field_prefix(opts, index)}metadata"
           ),
         {:ok, %Agent{} = resolved_callable_agent} <-
           get_record_by_id(Agent, callable_agent_id, actor),
         {:ok, callable_agent_version_id} <-
           resolve_callable_agent_version_id(
             resolved_callable_agent.id,
             version,
             actor,
             "#{field_prefix(opts, index)}version"
           ) do
      {:ok,
       %{
         user_id: user_id,
         callable_agent_id: resolved_callable_agent.id,
         callable_agent_version_id: callable_agent_version_id,
         position: index,
         metadata: metadata
       }}
    end
  end

  defp normalize_callable_agent_link(_callable_agent, index, _actor, opts) do
    {:error,
     {:invalid_request,
      "#{field_prefix(opts, index) |> String.trim_trailing(".")} must be an object."}}
  end

  defp get_record_by_id(resource, id, actor) do
    query =
      resource
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(actor))

    case Ash.read_one(query) do
      {:ok, nil} ->
        {:error,
         {:invalid_request, "#{Ash.Resource.Info.short_name(resource)} #{id} was not found."}}

      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_callable_agent_version_id(_agent_id, nil, _actor, _field), do: {:ok, nil}

  defp resolve_callable_agent_version_id(agent_id, version, actor, field) do
    query =
      AgentVersion
      |> Ash.Query.for_read(:read, %{}, ash_opts(actor))
      |> Ash.Query.filter(agent_id == ^agent_id and version == ^version)

    case Ash.read_one(query) do
      {:ok, nil} ->
        {:error, {:invalid_request, "#{field} references an unknown callable agent version."}}

      {:ok, agent_version} ->
        {:ok, agent_version.id}

      {:error, error} ->
        {:error, error}
    end
  end

  defp version_contents(version, owner_id) do
    %{
      name: version.name,
      description: version.description,
      model: version.model,
      system: version.system,
      tools: version.tools,
      mcp_servers: version.mcp_servers,
      metadata: version.metadata,
      agent_version_skills: version_skill_links(version, owner_id),
      agent_version_callable_agents: version_callable_agent_links(version, owner_id)
    }
  end

  defp version_skill_links(version, owner_id) do
    version.agent_version_skills
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn skill_link ->
      %{
        user_id: owner_id,
        skill_id: skill_link.skill_id,
        skill_version_id: skill_link.skill_version_id,
        position: skill_link.position,
        metadata: skill_link.metadata || %{}
      }
    end)
  end

  defp version_callable_agent_links(version, owner_id) do
    version.agent_version_callable_agents
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn callable_agent_link ->
      %{
        user_id: owner_id,
        callable_agent_id: callable_agent_link.callable_agent_id,
        callable_agent_version_id: callable_agent_link.callable_agent_version_id,
        position: callable_agent_link.position,
        metadata: callable_agent_link.metadata || %{}
      }
    end)
  end

  defp agent_requires_sync?(agent, attrs) do
    agent.name != attrs.name ||
      agent.description != attrs.description ||
      agent.metadata != attrs.metadata
  end

  defp merge_required_string(params, field, current) do
    if Map.has_key?(params, field) do
      required_string(params, field)
    else
      {:ok, current}
    end
  end

  defp merge_optional_string(params, field, current) do
    if Map.has_key?(params, field) do
      optional_string(Map.get(params, field), field)
    else
      {:ok, current}
    end
  end

  defp merge_model(params, current) do
    if Map.has_key?(params, "model") do
      normalize_model(Map.get(params, "model"))
    else
      {:ok, current}
    end
  end

  defp merge_metadata(params, current) do
    if Map.has_key?(params, "metadata") do
      with {:ok, metadata} <- required_map_value(Map.get(params, "metadata"), "metadata") do
        {:ok, merge_metadata_values(current || %{}, metadata)}
      end
    else
      {:ok, current || %{}}
    end
  end

  defp merge_array_of_maps(params, field, current) do
    if Map.has_key?(params, field) do
      required_array_of_maps(Map.get(params, field), field)
    else
      {:ok, current || []}
    end
  end

  defp merge_tool_declarations(params, current) do
    if Map.has_key?(params, "tools") do
      normalize_tool_declarations_required(Map.get(params, "tools"), field: "tools")
    else
      {:ok, current || []}
    end
  end

  defp merge_skill_links(params, current, actor, owner_id) do
    if Map.has_key?(params, "skills") do
      normalize_skill_links_required(Map.get(params, "skills"), actor,
        field: "skills",
        user_id: owner_id
      )
    else
      {:ok, current}
    end
  end

  defp merge_callable_agent_links(params, current, actor, owner_id) do
    if Map.has_key?(params, "callable_agents") do
      normalize_callable_agent_links_required(Map.get(params, "callable_agents"), actor,
        field: "callable_agents",
        user_id: owner_id
      )
    else
      {:ok, current}
    end
  end

  defp merge_metadata_values(current, incoming) do
    incoming
    |> stringify_top_level_keys()
    |> Enum.reduce(current, fn
      {key, ""}, metadata -> Map.delete(metadata, key)
      {key, value}, metadata -> Map.put(metadata, key, value)
    end)
  end

  defp normalize_skill_links_required(skills, actor, opts) when is_list(skills) do
    normalize_skill_links(skills, actor, opts)
  end

  defp normalize_skill_links_required(_skills, _actor, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp normalize_callable_agent_links_required(callable_agents, actor, opts)
       when is_list(callable_agents) do
    normalize_callable_agent_links(callable_agents, actor, opts)
  end

  defp normalize_callable_agent_links_required(_callable_agents, _actor, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp required_string(params, field, opts \\ []) do
    value = Map.get(params, field)
    prefix = Keyword.get(opts, :prefix, "")

    if present_string?(value) do
      {:ok, value}
    else
      {:error, {:invalid_request, "#{prefix}#{field} is required."}}
    end
  end

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_string(_value, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp required_positive_integer(params, field) do
    case Map.get(params, field) do
      value when is_integer(value) and value >= 1 ->
        {:ok, value}

      nil ->
        {:error, {:invalid_request, "#{field} is required."}}

      _other ->
        {:error, {:invalid_request, "#{field} must be a positive integer."}}
    end
  end

  defp optional_integer(nil, _field), do: {:ok, nil}
  defp optional_integer(value, _field) when is_integer(value) and value >= 1, do: {:ok, value}

  defp optional_integer(_value, field) do
    {:error, {:invalid_request, "#{field} must be a positive integer."}}
  end

  defp required_array_of_maps(values, field) when is_list(values) do
    if Enum.all?(values, &is_map/1) do
      {:ok, values}
    else
      {:error, {:invalid_request, "#{field} must be an array of objects."}}
    end
  end

  defp required_array_of_maps(_values, field) do
    {:error, {:invalid_request, "#{field} must be an array of objects."}}
  end

  defp normalize_tool_declarations_required(values, opts) when is_list(values) do
    case ToolDeclaration.normalize_many(values) do
      {:ok, normalized_values} ->
        {:ok, normalized_values}

      {:error, details} ->
        {:error,
         {:invalid_request, ToolDeclaration.format_error(Keyword.fetch!(opts, :field), details)}}
    end
  end

  defp normalize_tool_declarations_required(_values, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp required_map_value(value, _field) when is_map(value), do: {:ok, value}

  defp required_map_value(_value, field) do
    {:error, {:invalid_request, "#{field} must be an object."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp field_prefix(opts, index), do: "#{Keyword.fetch!(opts, :field)}[#{index}]."

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)
end
