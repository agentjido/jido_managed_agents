defmodule JidoManagedAgents.Sessions.RuntimeSkills do
  @moduledoc false

  alias Ash.NotLoaded
  alias Jido.AI.Skill.Spec
  alias JidoManagedAgents.Agents.{AgentVersion, Skill, SkillVersion}

  @type resolution_mode :: :latest | :pinned

  @spec resolve(AgentVersion.t() | nil) ::
          {:ok, [Spec.t()]} | {:error, {:invalid_request, String.t()}}
  def resolve(nil), do: {:ok, []}

  def resolve(%AgentVersion{} = agent_version) do
    with {:ok, skill_links} <- skill_links(agent_version) do
      skill_links
      |> Enum.sort_by(&Map.get(&1, :position, 0))
      |> Enum.reduce_while({:ok, []}, fn skill_link, {:ok, acc} ->
        with {:ok, {skill, version, resolution_mode}} <- resolve_skill_version(skill_link) do
          {:cont, {:ok, acc ++ [build_spec(skill, version, resolution_mode)]}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @spec resolve_skill_version(map()) ::
          {:ok, {Skill.t(), SkillVersion.t(), resolution_mode()}}
          | {:error, {:invalid_request, String.t()}}
  def resolve_skill_version(%{} = skill_link) do
    with {:ok, %Skill{} = skill} <- resolve_persisted_skill(skill_link),
         {:ok, %SkillVersion{} = version, resolution_mode} <-
           resolve_persisted_skill_version(skill_link, skill) do
      {:ok, {skill, version, resolution_mode}}
    end
  end

  defp skill_links(%AgentVersion{agent_version_skills: %NotLoaded{}}) do
    {:error, {:invalid_request, "Persisted runtime skill relationships were not loaded."}}
  end

  defp skill_links(%AgentVersion{agent_version_skills: skill_links}) when is_list(skill_links),
    do: {:ok, skill_links}

  defp skill_links(%AgentVersion{}), do: {:ok, []}

  defp resolve_persisted_skill(%{skill: %Skill{} = skill}), do: {:ok, skill}

  defp resolve_persisted_skill(%{skill: %NotLoaded{}}) do
    {:error, {:invalid_request, "Persisted runtime skill relationships were not loaded."}}
  end

  defp resolve_persisted_skill(%{skill: nil, skill_id: skill_id}) when is_binary(skill_id) do
    {:error, {:invalid_request, "Persisted runtime skill #{skill_id} was not found."}}
  end

  defp resolve_persisted_skill(%{skill_id: skill_id}) when is_binary(skill_id) do
    {:error, {:invalid_request, "Persisted runtime skill #{skill_id} could not be resolved."}}
  end

  defp resolve_persisted_skill(_skill_link) do
    {:error, {:invalid_request, "Persisted runtime skill link is invalid."}}
  end

  defp resolve_persisted_skill_version(
         %{skill_version: %SkillVersion{} = skill_version, skill_version_id: skill_version_id},
         _skill
       )
       when is_binary(skill_version_id) do
    {:ok, skill_version, :pinned}
  end

  defp resolve_persisted_skill_version(
         %{skill_version: %NotLoaded{}, skill_version_id: skill_version_id},
         _skill
       )
       when is_binary(skill_version_id) do
    {:error,
     {:invalid_request,
      "Persisted runtime skill version #{skill_version_id} was not loaded for resolution."}}
  end

  defp resolve_persisted_skill_version(
         %{skill_version: nil, skill_version_id: skill_version_id},
         _skill
       )
       when is_binary(skill_version_id) do
    {:error,
     {:invalid_request, "Persisted runtime skill version #{skill_version_id} was not found."}}
  end

  defp resolve_persisted_skill_version(%{skill_version_id: nil}, %Skill{
         latest_version: %SkillVersion{} = latest_version
       }) do
    {:ok, latest_version, :latest}
  end

  defp resolve_persisted_skill_version(%{skill_version_id: nil}, %Skill{
         latest_version: %NotLoaded{}
       }) do
    {:error,
     {:invalid_request, "Persisted runtime skill latest-version relationships were not loaded."}}
  end

  defp resolve_persisted_skill_version(%{skill_id: skill_id, skill_version_id: nil}, %Skill{
         latest_version: nil
       })
       when is_binary(skill_id) do
    {:error,
     {:invalid_request, "Persisted runtime skill #{skill_id} does not have an available version."}}
  end

  defp resolve_persisted_skill_version(%{skill_id: skill_id}, _skill) when is_binary(skill_id) do
    {:error,
     {:invalid_request, "Persisted runtime skill #{skill_id} could not resolve a version."}}
  end

  defp resolve_persisted_skill_version(_skill_link, _skill) do
    {:error, {:invalid_request, "Persisted runtime skill version link is invalid."}}
  end

  defp build_spec(%Skill{} = skill, %SkillVersion{} = version, resolution_mode) do
    manifest = stringify_keys(version.manifest || %{})

    %Spec{
      name: skill.name,
      description: version.description || skill.description || skill.name,
      license: optional_string(Map.get(manifest, "license")),
      compatibility: optional_string(Map.get(manifest, "compatibility")),
      metadata: skill_metadata(skill, version, manifest, resolution_mode),
      allowed_tools: allowed_tools(version, manifest),
      source: source_ref(version.source_path),
      body_ref: body_ref(version),
      actions: [],
      plugins: [],
      vsn: Integer.to_string(version.version),
      tags: string_list(Map.get(manifest, "tags"))
    }
  end

  defp skill_metadata(%Skill{} = skill, %SkillVersion{} = version, manifest, resolution_mode) do
    manifest_metadata = Map.get(manifest, "metadata")

    %{}
    |> Map.merge(map_value(manifest_metadata))
    |> Map.merge(map_value(skill.metadata))
    |> Map.merge(map_value(version.metadata))
    |> Map.put("skill_id", skill.id)
    |> Map.put("skill_type", skill.type |> Atom.to_string())
    |> Map.put("skill_version_id", version.id)
    |> Map.put("skill_version", version.version)
    |> Map.put("resolution_mode", Atom.to_string(resolution_mode))
  end

  defp allowed_tools(%SkillVersion{allowed_tools: allowed_tools}, manifest)
       when is_list(allowed_tools) do
    if allowed_tools == [] do
      string_list(Map.get(manifest, "allowed_tools"))
    else
      Enum.map(allowed_tools, &to_string/1)
    end
  end

  defp allowed_tools(_version, manifest), do: string_list(Map.get(manifest, "allowed_tools"))

  defp source_ref(nil), do: nil

  defp source_ref(source_path) when is_binary(source_path) do
    case skill_prompt_path(source_path) do
      nil -> nil
      prompt_path -> {:file, prompt_path}
    end
  end

  defp source_ref(_source_path), do: nil

  defp body_ref(%SkillVersion{body: body}) when is_binary(body) do
    case String.trim(body) do
      "" -> nil
      _body -> {:inline, body}
    end
  end

  defp body_ref(%SkillVersion{source_path: source_path}) when is_binary(source_path) do
    case skill_prompt_path(source_path) do
      nil -> nil
      prompt_path -> {:file, prompt_path}
    end
  end

  defp body_ref(_version), do: nil

  defp skill_prompt_path(source_path) do
    expanded_path = Path.expand(source_path)

    cond do
      File.regular?(expanded_path) and Path.basename(expanded_path) == "SKILL.md" ->
        expanded_path

      File.dir?(expanded_path) ->
        prompt_path = Path.join(expanded_path, "SKILL.md")
        if File.regular?(prompt_path), do: prompt_path, else: nil

      true ->
        nil
    end
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _value -> value
    end
  end

  defp optional_string(_value), do: nil

  defp string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp string_list(_values), do: []

  defp map_value(%{} = value), do: value
  defp map_value(_value), do: %{}

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_value), do: %{}
end
