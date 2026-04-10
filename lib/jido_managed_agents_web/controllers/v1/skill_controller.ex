defmodule JidoManagedAgentsWeb.V1.SkillController do
  use JidoManagedAgentsWeb.V1.Controller

  require Ash.Query

  alias JidoManagedAgents.Agents
  alias JidoManagedAgents.Agents.Skill
  alias JidoManagedAgents.Agents.SkillDefinition
  alias JidoManagedAgents.Agents.SkillVersion
  alias Plug.Conn

  @latest_load [:latest_version]

  def create(conn, params) do
    with {:ok, %{skill: skill_attrs, version: version_attrs}} <-
           SkillDefinition.normalize_create_payload(params),
         {:ok, %Skill{} = skill} <- create_skill(conn, skill_attrs, version_attrs) do
      conn
      |> Conn.put_status(:created)
      |> render_object(SkillDefinition.serialize_skill(skill, include_body?: true))
    end
  end

  def index(conn, _params) do
    query =
      Skill
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Agents))
      |> Ash.Query.filter(is_nil(archived_at))
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.load(@latest_load)

    with {:ok, skills} <- Ash.read(query) do
      render_list(conn, skills, &SkillDefinition.serialize_skill/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Skill{} = skill} <- fetch_skill(conn, id, @latest_load) do
      render_object(conn, SkillDefinition.serialize_skill(skill, include_body?: true))
    end
  end

  def versions(conn, %{"id" => id}) do
    with {:ok, %Skill{} = skill} <- fetch_skill(conn, id, []),
         {:ok, versions} <- list_versions(conn, skill) do
      render_list(conn, versions, &SkillDefinition.serialize_skill_version(skill, &1))
    end
  end

  defp fetch_skill(conn, id, load) do
    query =
      Skill
      |> Ash.Query.for_read(:by_id, %{id: id}, ash_opts(conn, domain: Agents))
      |> maybe_load(load)

    case Ash.read_one(query) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Skill{} = skill} -> {:ok, skill}
      {:error, error} -> {:error, error}
    end
  end

  defp list_versions(conn, skill) do
    query =
      SkillVersion
      |> Ash.Query.for_read(:read, %{}, ash_opts(conn, domain: Agents))
      |> Ash.Query.filter(skill_id == ^skill.id)
      |> Ash.Query.sort(version: :desc)

    Ash.read(query)
  end

  defp create_skill(conn, skill_attrs, version_attrs) do
    opts = ash_opts(conn, domain: Agents)
    resources = [Skill, SkillVersion]

    Ash.transact(resources, fn ->
      with {:ok, %Skill{} = skill} <- create_skill_record(skill_attrs, opts),
           {:ok, _version} <- create_initial_version(skill, version_attrs, opts),
           {:ok, %Skill{} = loaded_skill} <- load_skill(skill.id, opts) do
        loaded_skill
      end
    end)
  end

  defp create_skill_record(attrs, opts) do
    Skill
    |> Ash.Changeset.for_create(
      :create,
      Map.put(attrs, :user_id, Keyword.fetch!(opts, :actor).id),
      opts
    )
    |> Ash.create()
  end

  defp create_initial_version(skill, attrs, opts) do
    SkillVersion
    |> Ash.Changeset.for_create(
      :create,
      attrs
      |> Map.put(:user_id, skill.user_id)
      |> Map.put(:skill_id, skill.id)
      |> Map.put(:version, 1),
      opts
    )
    |> Ash.create()
  end

  defp load_skill(skill_id, opts) do
    query =
      Skill
      |> Ash.Query.for_read(:by_id, %{id: skill_id}, opts)
      |> Ash.Query.load(@latest_load)

    case Ash.read_one(query) do
      {:ok, %Skill{} = skill} -> {:ok, skill}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)
end
