defmodule JidoManagedAgents.Agents.SkillDefinition do
  @moduledoc """
  Normalization and serialization helpers for the persisted skill registry.
  """

  alias Jido.AI.Skill, as: JidoSkill
  alias Jido.AI.Skill.Loader, as: JidoSkillLoader
  alias Jido.AI.Skill.Spec
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Agents.SkillVersion

  @supported_types ~w(anthropic custom)

  @spec normalize_create_payload(map()) ::
          {:ok, %{skill: map(), version: map()}} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, source_content} <- resolve_source_content(Map.get(params, "source_path")),
         {:ok, skill_type} <- optional_skill_type(Map.get(params, "type"), "type"),
         {:ok, name} <-
           required_string_with_default(Map.get(params, "name"), source_content.name, "name"),
         {:ok, description} <-
           required_string_with_default(
             Map.get(params, "description"),
             source_content.description,
             "description"
           ),
         {:ok, body} <-
           optional_string_with_default(Map.get(params, "body"), source_content.body, "body"),
         {:ok, source_path} <- source_path_value(Map.get(params, "source_path")),
         {:ok, allowed_tools} <-
           string_array(Map.get(params, "allowed_tools"),
             default: source_content.allowed_tools,
             field: "allowed_tools"
           ),
         {:ok, metadata} <-
           map_value(Map.get(params, "metadata"), default: %{}, field: "metadata"),
         {:ok, version_metadata} <-
           map_value(Map.get(params, "version_metadata"), default: %{}, field: "version_metadata"),
         {:ok, manifest_override} <-
           map_value(Map.get(params, "manifest"), default: %{}, field: "manifest"),
         :ok <- ensure_skill_source(body, source_path) do
      {:ok,
       %{
         skill: %{
           type: String.to_existing_atom(skill_type),
           name: name,
           description: description,
           metadata: metadata
         },
         version: %{
           description: description,
           body: body,
           source_path: source_path,
           allowed_tools: allowed_tools,
           manifest: Map.merge(source_content.manifest, manifest_override),
           metadata: version_metadata
         }
       }}
    end
  rescue
    ArgumentError ->
      {:error, {:invalid_request, "type must be \"anthropic\" or \"custom\"."}}
  end

  def normalize_create_payload(_params) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec serialize_skill(struct(), keyword()) :: map()
  def serialize_skill(skill, opts \\ [])

  def serialize_skill(%Skill{} = skill, opts) do
    case Map.get(skill, :latest_version) do
      %SkillVersion{} = latest_version ->
        serialize_skill_snapshot(skill, latest_version,
          created_at: skill.created_at,
          updated_at: latest_version.updated_at,
          include_body?: Keyword.get(opts, :include_body?, false)
        )

      _other ->
        %{
          id: skill.id,
          type: "skill",
          skill_type: skill_type(skill),
          name: skill.name,
          description: skill.description,
          version: nil,
          metadata: skill.metadata || %{},
          version_metadata: %{},
          allowed_tools: [],
          manifest: %{},
          source_path: nil,
          archived_at: skill.archived_at,
          created_at: skill.created_at,
          updated_at: skill.updated_at
        }
    end
  end

  @spec serialize_skill_version(struct(), struct(), keyword()) :: map()
  def serialize_skill_version(%Skill{} = skill, %SkillVersion{} = version, opts \\ []) do
    serialize_skill_snapshot(skill, version,
      created_at: version.created_at,
      updated_at: version.updated_at,
      include_body?: Keyword.get(opts, :include_body?, false)
    )
  end

  defp serialize_skill_snapshot(skill, version, opts) do
    snapshot = %{
      id: skill.id,
      type: "skill",
      skill_type: skill_type(skill),
      name: skill.name,
      description: version.description,
      version: version.version,
      metadata: skill.metadata || %{},
      version_metadata: version.metadata || %{},
      allowed_tools: version.allowed_tools || [],
      manifest: version.manifest || %{},
      source_path: version.source_path,
      body: if(Keyword.fetch!(opts, :include_body?), do: version.body),
      archived_at: skill.archived_at,
      created_at: Keyword.fetch!(opts, :created_at),
      updated_at: Keyword.fetch!(opts, :updated_at)
    }

    if Keyword.fetch!(opts, :include_body?) do
      snapshot
    else
      Map.delete(snapshot, :body)
    end
  end

  defp skill_type(%Skill{type: type}) when is_atom(type), do: Atom.to_string(type)

  defp resolve_source_content(nil) do
    {:ok, %{name: nil, description: nil, body: nil, allowed_tools: [], manifest: %{}}}
  end

  defp resolve_source_content(source_path) when is_binary(source_path) do
    expanded_path = Path.expand(source_path)

    cond do
      File.regular?(expanded_path) and Path.basename(expanded_path) == "SKILL.md" ->
        load_skill_file(expanded_path)

      File.dir?(expanded_path) and File.regular?(Path.join(expanded_path, "SKILL.md")) ->
        load_skill_file(Path.join(expanded_path, "SKILL.md"))

      File.regular?(expanded_path) or File.dir?(expanded_path) ->
        {:ok, %{name: nil, description: nil, body: nil, allowed_tools: [], manifest: %{}}}

      true ->
        {:error, {:invalid_request, "source_path must point to an existing file or directory."}}
    end
  end

  defp resolve_source_content(_source_path) do
    {:error, {:invalid_request, "source_path must be a string or null."}}
  end

  defp load_skill_file(path) do
    case JidoSkillLoader.load(path) do
      {:ok, %Spec{} = spec} ->
        {:ok,
         %{
           name: spec.name,
           description: spec.description,
           body: JidoSkill.body(spec),
           allowed_tools: spec.allowed_tools,
           manifest: manifest_from_spec(spec)
         }}

      {:error, error} ->
        {:error, {:invalid_request, Exception.message(error)}}
    end
  end

  defp manifest_from_spec(%Spec{} = spec) do
    %{
      "name" => spec.name,
      "description" => spec.description,
      "license" => spec.license,
      "compatibility" => spec.compatibility,
      "metadata" => spec.metadata || %{},
      "allowed_tools" => spec.allowed_tools || [],
      "version" => spec.vsn,
      "tags" => spec.tags || []
    }
    |> compact_map()
  end

  defp optional_skill_type(nil, _field), do: {:ok, "custom"}

  defp optional_skill_type(type, field) when is_atom(type),
    do: optional_skill_type(Atom.to_string(type), field)

  defp optional_skill_type(type, _field) when is_binary(type) and type in @supported_types,
    do: {:ok, type}

  defp optional_skill_type(_type, field) do
    {:error, {:invalid_request, "#{field} must be \"anthropic\" or \"custom\"."}}
  end

  defp source_path_value(nil), do: {:ok, nil}

  defp source_path_value(source_path) when is_binary(source_path) do
    expanded_path = Path.expand(source_path)

    if File.regular?(expanded_path) or File.dir?(expanded_path) do
      {:ok, expanded_path}
    else
      {:error, {:invalid_request, "source_path must point to an existing file or directory."}}
    end
  end

  defp source_path_value(_source_path) do
    {:error, {:invalid_request, "source_path must be a string or null."}}
  end

  defp required_string_with_default(value, default, field) do
    case coalesce_string(value, default) do
      string when is_binary(string) ->
        if String.trim(string) == "" do
          {:error, {:invalid_request, "#{field} is required."}}
        else
          {:ok, string}
        end

      _other ->
        {:error, {:invalid_request, "#{field} is required."}}
    end
  end

  defp optional_string_with_default(nil, default, _field), do: {:ok, default}

  defp optional_string_with_default(value, _default, _field) when is_binary(value),
    do: {:ok, value}

  defp optional_string_with_default(_value, _default, field) do
    {:error, {:invalid_request, "#{field} must be a string or null."}}
  end

  defp string_array(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}

  defp string_array(values, _opts) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, {:invalid_request, "allowed_tools must be an array of strings."}}
    end
  end

  defp string_array(_values, _opts) do
    {:error, {:invalid_request, "allowed_tools must be an array of strings."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp ensure_skill_source(body, _source_path) when is_binary(body) and byte_size(body) > 0,
    do: :ok

  defp ensure_skill_source(nil, source_path) when is_binary(source_path), do: :ok
  defp ensure_skill_source("", source_path) when is_binary(source_path), do: :ok

  defp ensure_skill_source(_body, _source_path) do
    {:error, {:invalid_request, "body or source_path is required."}}
  end

  defp coalesce_string(value, _default) when is_binary(value) and value != "", do: value
  defp coalesce_string(_value, default) when is_binary(default) and default != "", do: default
  defp coalesce_string(_value, _default), do: nil

  defp compact_map(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      _other -> false
    end)
  end

  defp stringify_top_level_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
