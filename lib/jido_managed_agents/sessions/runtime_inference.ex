defmodule JidoManagedAgents.Sessions.RuntimeInference do
  @moduledoc false

  alias Jido.AI.Directive.Helpers, as: DirectiveHelpers
  alias Jido.AI.Skill.Prompt, as: SkillPrompt
  alias Jido.AI.Skill.Spec
  alias JidoManagedAgents.Agents.{AgentModel, AgentVersion}
  alias JidoManagedAgents.Sessions.{RuntimeSkills, SessionEvent}
  alias ReqLLM.Response

  @default_config %{
    anthropic_compatible_provider: :anthropic,
    max_tokens: 1024,
    temperature: 0.2,
    timeout: 30_000,
    req_http_options: []
  }

  defmodule Result do
    @moduledoc false

    @type t :: %__MODULE__{
            text: String.t(),
            thinking: String.t() | nil,
            model: String.t(),
            provider: String.t(),
            usage: map()
          }

    @enforce_keys [:text, :model, :provider, :usage]
    defstruct [:text, :thinking, :model, :provider, :usage]
  end

  defmodule Request do
    @moduledoc false

    @type t :: %__MODULE__{
            model: ReqLLM.model_input(),
            model_label: String.t(),
            provider: String.t(),
            system_prompt: String.t() | nil,
            skills: [Spec.t()],
            max_tokens: pos_integer(),
            temperature: number(),
            timeout: pos_integer(),
            req_http_options: keyword()
          }

    @enforce_keys [
      :model,
      :model_label,
      :provider,
      :max_tokens,
      :temperature,
      :timeout,
      :req_http_options,
      :skills
    ]
    defstruct [
      :model,
      :model_label,
      :provider,
      :system_prompt,
      :max_tokens,
      :temperature,
      :timeout,
      req_http_options: [],
      skills: []
    ]
  end

  @type error_details :: %{
          required(:message) => String.t(),
          required(:error_type) => String.t(),
          optional(:provider) => String.t(),
          optional(:model) => String.t()
        }

  @spec generate(AgentVersion.t() | nil, SessionEvent.t()) ::
          {:ok, Result.t()} | {:error, error_details()}
  def generate(agent_version, %SessionEvent{} = event) do
    with {:ok, prompt} <- prompt_from_event(event),
         {:ok, response, request} <- chat(agent_version, prompt) do
      {:ok, response_to_result(response, request)}
    else
      {:error, %{} = error} -> {:error, stringify_error_details(error)}
      {:error, error} -> {:error, error_details(nil, error)}
    end
  end

  @spec chat(AgentVersion.t() | nil, term(), keyword()) ::
          {:ok, Response.t(), Request.t()} | {:error, error_details()}
  def chat(agent_version, input, opts \\ []) do
    with {:ok, request} <- build_request(agent_version),
         {:ok, response} <- request_text(input, request, Keyword.drop(opts, [:actor])) do
      {:ok, response, request}
    else
      {:error, %{} = error} -> {:error, stringify_error_details(error)}
      {:error, error} -> {:error, error_details(nil, error)}
    end
  end

  @spec build_request(AgentVersion.t() | nil) :: {:ok, Request.t()} | {:error, error_details()}
  def build_request(nil) do
    {:error,
     error_details(
       nil,
       {:invalid_request, "Session is missing an agent version for runtime inference."}
     )}
  end

  def build_request(%AgentVersion{} = agent_version) do
    config = runtime_config()

    with {:ok, model} <- normalize_runtime_model(agent_version.model, config) do
      request = base_request(model, config)

      with {:ok, skills} <- RuntimeSkills.resolve(agent_version) do
        {:ok,
         %Request{
           request
           | system_prompt: build_system_prompt(agent_version.system, skills),
             skills: skills
         }}
      else
        {:error, error} ->
          {:error, error_details(request, error)}
      end
    else
      {:error, %{} = error} -> {:error, stringify_error_details(error)}
      {:error, error} -> {:error, error_details(nil, error)}
    end
  end

  defp base_request(model, config) do
    %Request{
      model: model,
      model_label: Jido.AI.model_label(model),
      provider: normalize_provider(model),
      system_prompt: nil,
      skills: [],
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      timeout: config.timeout,
      req_http_options: config.req_http_options
    }
  end

  defp build_system_prompt(system_prompt, skills) do
    skill_prompt = SkillPrompt.render(skills)

    case {normalize_optional_text(system_prompt), normalize_optional_text(skill_prompt)} do
      {nil, nil} -> nil
      {system_prompt, nil} -> system_prompt
      {nil, skill_prompt} -> skill_prompt
      {system_prompt, skill_prompt} -> system_prompt <> "\n\n" <> skill_prompt
    end
  end

  defp request_text(input, %Request{} = request, opts) do
    request_opts =
      [
        model: request.model,
        system_prompt: request.system_prompt,
        max_tokens: request.max_tokens,
        temperature: request.temperature,
        timeout: request.timeout,
        req_http_options: request.req_http_options
      ]
      |> Keyword.merge(opts)

    try do
      Jido.AI.generate_text(input, request_opts)
      |> case do
        {:ok, response} -> {:ok, response}
        {:error, error} -> {:error, error_details(request, error)}
      end
    rescue
      error ->
        {:error, error_details(request, error)}
    catch
      kind, reason ->
        {:error, error_details(request, {kind, reason})}
    end
  end

  defp response_to_result(response, %Request{} = request) do
    text = ReqLLM.Response.text(response) || ""
    thinking = normalize_optional_text(ReqLLM.Response.thinking(response))

    %Result{
      text: normalize_response_text(text),
      thinking: thinking,
      model: response.model || request.model_label,
      provider: request.provider,
      usage: normalize_usage(ReqLLM.Response.usage(response))
    }
  end

  defp normalize_runtime_model(model, config) when is_binary(model) do
    model = String.trim(model)

    cond do
      model == "" ->
        {:error, {:invalid_request, "Session agent model cannot be blank."}}

      String.contains?(model, ":") ->
        normalize_reqllm_model(model)

      true ->
        normalize_reqllm_model(%{
          "provider" => config.anthropic_compatible_provider,
          "id" => model
        })
    end
  end

  defp normalize_runtime_model(model, config) when is_map(model) do
    model =
      model
      |> AgentModel.serialize_for_response()
      |> stringify_keys()

    cond do
      present_string?(model["provider"]) and present_string?(model["id"]) ->
        normalize_reqllm_model(model)

      present_string?(model["provider"]) and present_string?(model["model"]) ->
        normalize_reqllm_model(model)

      present_string?(model["id"]) ->
        normalize_reqllm_model(%{
          "provider" => config.anthropic_compatible_provider,
          "id" => model["id"]
        })

      true ->
        {:error, {:invalid_request, "Session agent model is not a valid runtime model spec."}}
    end
  end

  defp normalize_runtime_model(_model, _config) do
    {:error, {:invalid_request, "Session agent model is not a valid runtime model spec."}}
  end

  defp normalize_reqllm_model(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{} = normalized} ->
        {:ok, normalized}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prompt_from_event(%SessionEvent{} = event) do
    case extract_text_content(event.content) do
      "" ->
        {:error,
         {:invalid_request,
          "user.message content must include at least one text block for provider-backed inference."}}

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

  defp error_details(request, {:invalid_request, message}) when is_binary(message) do
    base_error_details(request, message, :validation)
  end

  defp error_details(request, {:error, error}), do: error_details(request, error)

  defp error_details(request, error) do
    base_error_details(request, error_message(error), error_type(error))
  end

  defp base_error_details(request, message, error_type) do
    %{
      message: message,
      error_type: to_string(error_type)
    }
    |> maybe_put_request_context(request)
  end

  defp maybe_put_request_context(details, nil), do: details

  defp maybe_put_request_context(details, %Request{} = request) do
    details
    |> Map.put(:provider, request.provider)
    |> Map.put(:model, request.model_label)
  end

  defp error_message(%{message: message}) when is_binary(message) and message != "", do: message
  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(:timeout), do: "Request timed out."
  defp error_message(error) when is_binary(error) and error != "", do: error
  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error), do: inspect(error)

  defp error_type({:invalid_request, _message}), do: :validation
  defp error_type({:error, error}), do: error_type(error)
  defp error_type(error), do: DirectiveHelpers.classify_error(error)

  defp normalize_provider(model) do
    model
    |> Map.get(:provider)
    |> to_string()
  end

  defp normalize_response_text(text) when is_binary(text) do
    if String.trim(text) == "" do
      "Provider-backed inference completed without text output."
    else
      text
    end
  end

  defp normalize_optional_text(text) when is_binary(text) do
    text = String.trim(text)
    if text == "", do: nil, else: text
  end

  defp normalize_optional_text(_text), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    usage
    |> stringify_keys()
    |> Map.take([
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "cached_tokens",
      "reasoning_tokens"
    ])
  end

  defp normalize_usage(_usage), do: %{}

  defp stringify_error_details(details) do
    details
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, value} end)
  end

  defp runtime_config do
    configured =
      Application.get_env(:jido_managed_agents, JidoManagedAgents.Sessions.SessionRuntime, [])
      |> Map.new()

    Map.merge(@default_config, configured, fn
      :req_http_options, _default, value when is_list(value) -> value
      _key, default, nil -> default
      _key, _default, value -> value
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
