defmodule JidoManagedAgents.Agents.ModelCatalog do
  @moduledoc false

  @default_allow [
    anthropic: :all,
    openai: :all,
    google: :all,
    groq: :all,
    mistral: :all,
    xai: :all
  ]

  @type allowlist :: keyword(:all | [String.t()])

  @spec provider_options(atom() | String.t() | nil) :: [{String.t(), String.t()}]
  def provider_options(current_provider \\ nil) do
    current_provider = normalize_provider(current_provider)

    allowed_provider_ids()
    |> maybe_append_provider(current_provider)
    |> Enum.map(fn provider_id ->
      {provider_label(provider_id), Atom.to_string(provider_id)}
    end)
  end

  @spec model_options(atom() | String.t() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def model_options(provider, current_model_id \\ nil) do
    provider = normalize_provider(provider)
    current_model_id = normalize_model_id(current_model_id)

    provider
    |> allowed_models()
    |> maybe_append_model(provider, current_model_id)
    |> Enum.map(fn model -> {model_label(model), model.id} end)
  end

  @spec default_provider() :: atom() | nil
  def default_provider do
    allowed_provider_ids() |> List.first()
  end

  @spec default_model(atom() | String.t() | nil) :: LLMDB.Model.t() | nil
  def default_model(provider) do
    provider
    |> normalize_provider()
    |> allowed_models()
    |> List.first()
  end

  @spec resolve(atom() | String.t() | nil, String.t() | nil) :: {:ok, LLMDB.Model.t()} | :error
  def resolve(provider, model_id) do
    with provider when not is_nil(provider) <- normalize_provider(provider),
         model_id when is_binary(model_id) and model_id != "" <- normalize_model_id(model_id),
         {:ok, model} <- LLMDB.model(provider, model_id) do
      {:ok, model}
    else
      _ -> :error
    end
  end

  @spec normalize_provider(atom() | String.t() | nil) :: atom() | nil
  def normalize_provider(nil), do: nil
  def normalize_provider(""), do: nil
  def normalize_provider(provider) when is_atom(provider), do: provider

  def normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> case do
      "" ->
        nil

      value ->
        case LLMDB.Spec.parse_provider(value) do
          {:ok, provider_id} -> provider_id
          {:error, _reason} -> nil
        end
    end
  end

  @spec active_chat_model?(LLMDB.Model.t()) :: boolean()
  def active_chat_model?(%LLMDB.Model{} = model) do
    chat_enabled? = get_in(model.capabilities || %{}, [:chat]) != false
    chat_enabled? and not LLMDB.Model.retired?(model)
  end

  defp allowed_models(nil), do: []

  defp allowed_models(provider) do
    patterns_for(provider)
    |> case do
      nil ->
        []

      patterns ->
        provider
        |> LLMDB.models()
        |> Enum.filter(&active_chat_model?/1)
        |> Enum.filter(&allowed_model?(&1, patterns))
        |> sort_models()
    end
  end

  defp allowed_model?(_model, :all), do: true

  defp allowed_model?(%LLMDB.Model{} = model, patterns) when is_list(patterns) do
    identifiers = [model.id | List.wrap(model.aliases)]

    Enum.any?(patterns, fn pattern ->
      Enum.any?(identifiers, &matches_pattern?(&1, pattern))
    end)
  end

  defp allowed_provider_ids do
    ensure_loaded()

    allowlist()
    |> Keyword.keys()
    |> Enum.filter(fn provider_id ->
      match?({:ok, _provider}, LLMDB.provider(provider_id))
    end)
  end

  defp maybe_append_provider(provider_ids, nil), do: provider_ids

  defp maybe_append_provider(provider_ids, provider_id) do
    if provider_id in provider_ids or match?({:error, _}, LLMDB.provider(provider_id)) do
      provider_ids
    else
      provider_ids ++ [provider_id]
    end
  end

  defp maybe_append_model(models, _provider, nil), do: models

  defp maybe_append_model(models, provider, model_id) do
    if Enum.any?(models, &(&1.id == model_id)) do
      models
    else
      case resolve(provider, model_id) do
        {:ok, %LLMDB.Model{} = model} -> models ++ [model]
        :error -> models
      end
    end
  end

  defp provider_label(provider_id) do
    case LLMDB.provider(provider_id) do
      {:ok, provider} when is_binary(provider.name) and provider.name != "" ->
        provider.name

      _ ->
        provider_id
        |> Atom.to_string()
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp model_label(%LLMDB.Model{} = model) do
    base =
      cond do
        is_binary(model.name) and model.name != "" and model.name != model.id ->
          "#{model.name} (#{model.id})"

        true ->
          model.id
      end

    case LLMDB.Model.effective_status(model) do
      "deprecated" -> base <> " [Deprecated]"
      "retired" -> base <> " [Retired]"
      _status -> base
    end
  end

  defp sort_models(models) do
    models
    |> Enum.with_index()
    |> Enum.sort_by(fn {model, index} -> {lifecycle_rank(model), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp patterns_for(provider) do
    allowlist()
    |> Keyword.get(provider)
  end

  defp allowlist do
    Application.get_env(:jido_managed_agents, __MODULE__, [])
    |> Keyword.get(:allow, @default_allow)
  end

  defp normalize_model_id(model_id) when is_binary(model_id) do
    case String.trim(model_id) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_model_id(_model_id), do: nil

  defp matches_pattern?(value, pattern) when is_binary(value) and is_binary(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> then(&Regex.compile!("^" <> &1 <> "$", "i"))
    |> Regex.match?(value)
  end

  defp ensure_loaded do
    if LLMDB.providers() == [] do
      _ = LLMDB.load()
    end
  end

  defp lifecycle_rank(%LLMDB.Model{} = model) do
    case LLMDB.Model.effective_status(model) do
      "active" -> 0
      "deprecated" -> 1
      _status -> 2
    end
  end
end
