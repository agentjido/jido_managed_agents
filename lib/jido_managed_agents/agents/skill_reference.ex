defmodule JidoManagedAgents.Agents.SkillReference do
  @moduledoc false

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Agents.SkillVersion

  @supported_types ~w(anthropic custom)

  @type normalized_link :: %{
          user_id: String.t(),
          skill_id: String.t(),
          skill_version_id: String.t() | nil,
          position: non_neg_integer(),
          metadata: map()
        }

  @spec normalize_many(nil | list(), keyword()) ::
          {:ok, list(normalized_link())} | {:error, {:invalid_request, String.t()}}
  def normalize_many(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}

  def normalize_many(skills, opts) when is_list(skills) do
    skills
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {skill, index}, {:ok, acc} ->
      case normalize_one(skill, index, opts) do
        {:ok, normalized_skill} -> {:cont, {:ok, acc ++ [normalized_skill]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def normalize_many(_skills, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an array of objects."}}
  end

  defp normalize_one(skill, index, opts) when is_map(skill) do
    skill = stringify_top_level_keys(skill)
    skill_id = skill["skill_id"] || skill["id"]
    actor = Keyword.fetch!(opts, :actor)
    user_id = Keyword.get(opts, :user_id, actor.id)

    with {:ok, type} <- required_skill_type(skill["type"], "#{field_prefix(opts, index)}type"),
         {:ok, skill_id} <-
           required_string(%{"skill_id" => skill_id}, "skill_id",
             prefix: field_prefix(opts, index)
           ),
         {:ok, version} <-
           optional_integer(skill["version"], "#{field_prefix(opts, index)}version"),
         {:ok, metadata} <-
           map_value(skill["metadata"],
             default: %{},
             field: "#{field_prefix(opts, index)}metadata"
           ),
         {:ok, %Skill{} = resolved_skill} <- get_record_by_id(skill_id, actor),
         :ok <- validate_skill_type(resolved_skill, type, "#{field_prefix(opts, index)}type"),
         {:ok, skill_version_id} <-
           resolve_skill_version_id(
             resolved_skill.id,
             version,
             actor,
             "#{field_prefix(opts, index)}version"
           ) do
      {:ok,
       %{
         user_id: user_id,
         skill_id: resolved_skill.id,
         skill_version_id: skill_version_id,
         position: index,
         metadata: metadata
       }}
    end
  end

  defp normalize_one(_skill, index, opts) do
    {:error,
     {:invalid_request,
      "#{field_prefix(opts, index) |> String.trim_trailing(".")} must be an object."}}
  end

  defp get_record_by_id(id, actor) do
    query =
      Skill
      |> Ash.Query.for_read(:by_id, %{id: id}, actor: actor, domain: Agents)

    case Ash.read_one(query) do
      {:ok, nil} ->
        {:error, {:invalid_request, "skill #{id} was not found."}}

      {:ok, %Skill{} = record} ->
        {:ok, record}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resolve_skill_version_id(_skill_id, nil, _actor, _field), do: {:ok, nil}

  defp resolve_skill_version_id(skill_id, version, actor, field) do
    query =
      SkillVersion
      |> Ash.Query.for_read(:read, %{}, actor: actor, domain: Agents)
      |> Ash.Query.filter(skill_id == ^skill_id and version == ^version)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, {:invalid_request, "#{field} references an unknown skill version."}}
      {:ok, skill_version} -> {:ok, skill_version.id}
      {:error, error} -> {:error, error}
    end
  end

  defp required_skill_type(nil, field), do: {:error, {:invalid_request, "#{field} is required."}}

  defp required_skill_type(type, field) when is_atom(type),
    do: required_skill_type(Atom.to_string(type), field)

  defp required_skill_type(type, field) when is_binary(type) do
    if type in @supported_types do
      {:ok, type}
    else
      {:error, {:invalid_request, "#{field} must be \"anthropic\" or \"custom\"."}}
    end
  end

  defp required_skill_type(_type, field) do
    {:error, {:invalid_request, "#{field} must be \"anthropic\" or \"custom\"."}}
  end

  defp validate_skill_type(%Skill{type: type}, incoming_type, field) do
    if Atom.to_string(type) == incoming_type do
      :ok
    else
      {:error, {:invalid_request, "#{field} must match the referenced skill's persisted type."}}
    end
  end

  defp validate_skill_type(%Skill{}, _incoming_type, field) do
    {:error, {:invalid_request, "#{field} must match the referenced skill's persisted type."}}
  end

  defp required_string(params, field, opts) do
    value = Map.get(params, field)
    prefix = Keyword.get(opts, :prefix, "")

    if present_string?(value) do
      {:ok, value}
    else
      {:error, {:invalid_request, "#{prefix}#{field} is required."}}
    end
  end

  defp optional_integer(nil, _field), do: {:ok, nil}
  defp optional_integer(value, _field) when is_integer(value) and value >= 1, do: {:ok, value}

  defp optional_integer(_value, field) do
    {:error, {:invalid_request, "#{field} must be a positive integer."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp field_prefix(opts, index), do: "#{Keyword.fetch!(opts, :field)}[#{index}]."

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
