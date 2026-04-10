defmodule JidoManagedAgents.Agents.AgentDefinition do
  @moduledoc """
  Shared import, export, and serialization helpers for Anthropic-compatible
  agent definition bodies and `*.agent.yaml` files.
  """

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Agent
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

  @spec create_from_yaml(String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_from_yaml(yaml, opts \\ []) when is_binary(yaml) do
    with {:ok, params} <- parse_yaml(yaml),
         {:ok, payload} <- normalize_create_payload(params, opts),
         {:ok, %Agent{} = agent} <- create_agent(payload, opts) do
      {:ok, agent}
    end
  end

  @spec export_yaml(struct(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_yaml(%Agent{} = agent, opts \\ []) do
    with {:ok, definition} <- serialize_definition(agent, opts) do
      {:ok, Ymlr.document!(definition)}
    end
  end

  @spec parse_yaml(String.t()) :: {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def parse_yaml(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = document} ->
        {:ok, document}

      {:ok, _document} ->
        {:error, {:invalid_request, "Agent YAML must contain a single object document."}}

      {:error, error} ->
        {:error, {:invalid_request, Exception.message(error)}}
    end
  end

  @spec recommended_filename(String.t()) :: String.t()
  def recommended_filename(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if(slug == "", do: "agent", else: slug) <> ".agent.yaml"
  end

  @spec normalize_create_payload(map(), keyword()) ::
          {:ok, %{agent: map(), version: map()}} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params, opts \\ [])

  def normalize_create_payload(params, opts) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, name} <- required_string(params, "name"),
         {:ok, model} <- normalize_model(Map.get(params, "model")),
         {:ok, system} <- optional_string(Map.get(params, "system"), "system"),
         {:ok, description} <- optional_string(Map.get(params, "description"), "description"),
         {:ok, metadata} <-
           map_value(Map.get(params, "metadata"), default: %{}, field: "metadata"),
         {:ok, tools} <-
           normalize_tool_declarations(Map.get(params, "tools"), default: [], field: "tools"),
         {:ok, mcp_servers} <-
           array_of_maps(Map.get(params, "mcp_servers"), default: [], field: "mcp_servers"),
         {:ok, skills} <-
           normalize_skill_links(Map.get(params, "skills"), Keyword.put(opts, :field, "skills")),
         {:ok, callable_agents} <-
           normalize_callable_agent_links(
             Map.get(params, "callable_agents"),
             Keyword.put(opts, :field, "callable_agents")
           ) do
      {:ok,
       %{
         agent: %{
           name: name,
           description: description,
           metadata: metadata
         },
         version: %{
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
       }}
    end
  end

  def normalize_create_payload(_params, _opts) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec serialize_agent(struct()) :: map()
  def serialize_agent(%Agent{latest_version: %AgentVersion{} = latest_version} = agent) do
    serialize_agent_snapshot(agent, latest_version,
      created_at: agent.created_at,
      updated_at: latest_version.updated_at
    )
  end

  def serialize_agent(agent) do
    %{
      id: agent.id,
      type: "agent",
      name: agent.name,
      model: nil,
      system: nil,
      tools: [],
      mcp_servers: [],
      skills: [],
      callable_agents: [],
      description: agent.description,
      metadata: agent.metadata,
      version: nil,
      archived_at: agent.archived_at,
      created_at: agent.created_at,
      updated_at: agent.updated_at
    }
  end

  @spec serialize_agent_version(struct(), struct()) :: map()
  def serialize_agent_version(agent, version) do
    serialize_agent_snapshot(agent, version,
      created_at: version.created_at,
      updated_at: version.updated_at
    )
  end

  @spec serialize_definition(struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def serialize_definition(%Agent{} = agent, opts \\ []) do
    with {:ok, {_agent, version}} <- fetch_export_snapshot(agent, opts) do
      {:ok,
       %{
         "name" => version.name,
         "model" => AgentModel.serialize_for_definition(version.model),
         "system" => version.system,
         "tools" => version.tools || [],
         "mcp_servers" => version.mcp_servers || [],
         "skills" => serialize_skills(version),
         "callable_agents" => serialize_callable_agents(version),
         "description" => version.description,
         "metadata" => version.metadata || %{}
       }
       |> compact_map()}
    end
  end

  defp create_agent(%{agent: agent_attrs, version: version_attrs}, opts) do
    ash_opts = ash_opts(opts)
    resources = [Agent, AgentVersion, AgentVersionSkill, AgentVersionCallableAgent]

    Ash.transact(resources, fn ->
      with {:ok, %Agent{} = agent} <- create_agent_record(agent_attrs, ash_opts),
           {:ok, _version} <- create_initial_version(agent, version_attrs, ash_opts),
           {:ok, %Agent{} = loaded_agent} <- load_agent(agent.id, ash_opts) do
        loaded_agent
      end
    end)
  end

  defp fetch_export_snapshot(%Agent{} = agent, opts) do
    case Keyword.get(opts, :version) do
      nil ->
        with {:ok, %Agent{} = loaded_agent} <- load_agent(agent.id, ash_opts(opts)),
             %AgentVersion{} = latest_version <- loaded_agent.latest_version do
          {:ok, {loaded_agent, latest_version}}
        end

      version when is_integer(version) and version >= 1 ->
        with {:ok, %Agent{} = loaded_agent} <- load_agent(agent.id, ash_opts(opts)),
             {:ok, %AgentVersion{} = pinned_version} <-
               load_version(loaded_agent.id, version, ash_opts(opts)) do
          {:ok, {loaded_agent, pinned_version}}
        end

      _other ->
        {:error, {:invalid_request, "version must be a positive integer when provided."}}
    end
  end

  defp load_agent(agent_id, ash_opts) do
    query =
      Agent
      |> Ash.Query.for_read(:by_id, %{id: agent_id}, ash_opts)
      |> Ash.Query.load(@latest_version_load)

    case Ash.read_one(query) do
      {:ok, %Agent{} = agent} -> {:ok, agent}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp load_version(agent_id, version_number, ash_opts) do
    query =
      AgentVersion
      |> Ash.Query.for_read(:read, %{}, ash_opts)
      |> Ash.Query.filter(agent_id == ^agent_id and version == ^version_number)
      |> Ash.Query.load(@version_load)

    case Ash.read_one(query) do
      {:ok, %AgentVersion{} = version} -> {:ok, version}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp create_agent_record(attrs, ash_opts) do
    Agent
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, Keyword.fetch!(ash_opts, :actor).id),
      ash_opts
    )
    |> Ash.create()
  end

  defp create_initial_version(agent, attrs, ash_opts) do
    AgentVersion
    |> Ash.Changeset.for_create(
      :create,
      attrs
      |> Map.put(:user_id, agent.user_id)
      |> Map.put(:agent_id, agent.id)
      |> Map.put(:version, 1),
      ash_opts
    )
    |> Ash.create()
  end

  defp normalize_model(nil) do
    {:error, {:invalid_request, "model is required."}}
  end

  defp normalize_model(model), do: AgentModel.normalize(model)

  defp normalize_skill_links(nil, _opts), do: {:ok, []}

  defp normalize_skill_links(skills, opts),
    do: SkillReference.normalize_many(skills, Keyword.put(opts, :default, []))

  defp normalize_callable_agent_links(nil, _opts), do: {:ok, []}

  defp normalize_callable_agent_links(callable_agents, opts) when is_list(callable_agents) do
    callable_agents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {callable_agent, index}, {:ok, acc} ->
      case normalize_callable_agent_link(callable_agent, index, opts) do
        {:ok, normalized_callable_agent} ->
          {:cont, {:ok, acc ++ [normalized_callable_agent]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_callable_agent_links(_callable_agents, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp normalize_callable_agent_link(callable_agent, index, opts) when is_map(callable_agent) do
    callable_agent = stringify_top_level_keys(callable_agent)
    actor = Keyword.fetch!(opts, :actor)

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
         user_id: actor.id,
         callable_agent_id: resolved_callable_agent.id,
         callable_agent_version_id: callable_agent_version_id,
         position: index,
         metadata: metadata
       }}
    end
  end

  defp normalize_callable_agent_link(_callable_agent, index, opts) do
    {:error,
     {:invalid_request,
      "#{field_prefix(opts, index) |> String.trim_trailing(".")} must be an object."}}
  end

  defp get_record_by_id(resource, id, actor) do
    query =
      resource
      |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Agents)

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
      |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
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

  defp serialize_agent_snapshot(agent, version, opts) do
    %{
      id: agent.id,
      type: "agent",
      name: version.name,
      model: AgentModel.serialize_for_response(version.model),
      system: version.system,
      tools: version.tools || [],
      mcp_servers: version.mcp_servers || [],
      skills: serialize_skills(version),
      callable_agents: serialize_callable_agents(version),
      description: version.description,
      metadata: version.metadata,
      version: version.version,
      archived_at: agent.archived_at,
      created_at: Keyword.fetch!(opts, :created_at),
      updated_at: Keyword.fetch!(opts, :updated_at)
    }
  end

  defp serialize_skills(%AgentVersion{} = version) do
    version.agent_version_skills
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn skill_link ->
      compact_map(%{
        "type" => skill_type(skill_link),
        "skill_id" => skill_link.skill_id,
        "version" => skill_version_number(skill_link),
        "metadata" => present_map(skill_link.metadata)
      })
    end)
  end

  defp serialize_callable_agents(%AgentVersion{} = version) do
    version.agent_version_callable_agents
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn callable_agent_link ->
      compact_map(%{
        "type" => "agent",
        "id" => callable_agent_link.callable_agent_id,
        "version" => callable_agent_version_number(callable_agent_link),
        "metadata" => present_map(callable_agent_link.metadata)
      })
    end)
  end

  defp skill_type(%{skill: %{type: type}}) when is_atom(type), do: Atom.to_string(type)
  defp skill_type(_skill_link), do: "custom"

  defp skill_version_number(%{skill_version: %{version: version}}), do: version
  defp skill_version_number(_skill_link), do: nil

  defp callable_agent_version_number(%{callable_agent_version: %{version: version}}), do: version
  defp callable_agent_version_number(_callable_agent_link), do: nil

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

  defp optional_integer(nil, _field), do: {:ok, nil}
  defp optional_integer(value, _field) when is_integer(value) and value >= 1, do: {:ok, value}

  defp optional_integer(_value, field) do
    {:error, {:invalid_request, "#{field} must be a positive integer."}}
  end

  defp array_of_maps(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}

  defp array_of_maps(values, opts) when is_list(values) do
    if Enum.all?(values, &is_map/1) do
      {:ok, values}
    else
      {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
    end
  end

  defp array_of_maps(_values, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp normalize_tool_declarations(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}

  defp normalize_tool_declarations(values, opts) when is_list(values) do
    case ToolDeclaration.normalize_many(values) do
      {:ok, normalized_values} ->
        {:ok, normalized_values}

      {:error, details} ->
        {:error,
         {:invalid_request, ToolDeclaration.format_error(Keyword.fetch!(opts, :field), details)}}
    end
  end

  defp normalize_tool_declarations(_values, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp ash_opts(opts) do
    opts
    |> Keyword.take([:actor, :authorize?])
    |> Keyword.put(:domain, Agents)
  end

  defp field_prefix(opts, index), do: "#{Keyword.fetch!(opts, :field)}[#{index}]."

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp compact_map(map) do
    Enum.reject(map, fn
      {_key, nil} -> true
      {_key, value} when is_map(value) -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp present_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp present_map(_value), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
