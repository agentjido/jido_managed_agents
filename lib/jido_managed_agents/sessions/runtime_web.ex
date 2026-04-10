defmodule JidoManagedAgents.Sessions.RuntimeWeb do
  @moduledoc false

  alias Req.Response

  @default_fetch_max_chars 20_000
  @default_search_limit 5
  @default_user_agent "jido_managed_agents/0.1"

  @type error_details :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @spec default_fetch_max_chars() :: pos_integer()
  def default_fetch_max_chars, do: @default_fetch_max_chars

  @spec default_search_limit() :: pos_integer()
  def default_search_limit, do: @default_search_limit

  @spec fetch(String.t(), keyword()) :: {:ok, map()} | {:error, error_details()}
  def fetch(url, opts \\ [])

  def fetch(url, opts) when is_binary(url) do
    url = String.trim(url)

    max_chars =
      normalize_positive_integer(Keyword.get(opts, :max_chars), @default_fetch_max_chars)

    with :ok <- validate_url(url),
         {:ok, response} <- request(url, fetch_req_options(opts)),
         {:ok, result} <- normalize_fetch_response(url, response, max_chars) do
      {:ok, result}
    end
  end

  def fetch(_url, _opts), do: {:error, invalid_input("URL must be a non-empty string.")}

  @spec search(String.t(), keyword()) :: {:ok, map()} | {:error, error_details()}
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    query = String.trim(query)
    limit = normalize_positive_integer(Keyword.get(opts, :limit), @default_search_limit)
    adapter = Keyword.get(opts, :adapter, JidoManagedAgents.Sessions.RuntimeWeb.DuckDuckGoAdapter)
    adapter_opts = Keyword.get(opts, :adapter_options, [])

    with :ok <- validate_query(query),
         {:ok, results} <- adapter.search(query, Keyword.put(adapter_opts, :limit, limit)) do
      {:ok,
       %{
         "query" => query,
         "results" => normalize_search_results(results, limit)
       }}
    else
      {:error, %{} = error} -> {:error, normalize_error_map(error, "search_error")}
      {:error, error} -> {:error, normalize_search_error(error)}
    end
  end

  def search(_query, _opts), do: {:error, invalid_input("Query must be a non-empty string.")}

  @spec normalize_search_results(term(), pos_integer()) :: [map()]
  def normalize_search_results(results, limit)
      when is_list(results) and is_integer(limit) and limit > 0 do
    results
    |> Enum.map(&normalize_search_result/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  def normalize_search_results(_results, _limit), do: []

  @spec normalize_search_error(term()) :: error_details()
  def normalize_search_error(error) when is_exception(error) do
    base_error_details(error, "search_error")
  end

  def normalize_search_error(%{} = error), do: normalize_error_map(error, "search_error")

  def normalize_search_error(error) do
    base_error_details(error, "search_error")
  end

  @spec normalize_http_error(term()) :: error_details()
  def normalize_http_error(error) when is_exception(error) do
    base_error_details(error, "network_error")
  end

  def normalize_http_error(%{} = error), do: normalize_error_map(error, "network_error")

  def normalize_http_error(error) do
    base_error_details(error, "network_error")
  end

  defp request(url, req_options) do
    request_options = Keyword.merge([method: :get, url: url], req_options)

    case Req.request(request_options) do
      {:ok, %Response{} = response} -> {:ok, response}
      {:error, error} -> {:error, normalize_http_error(error)}
    end
  end

  defp fetch_req_options(opts) do
    default_headers = [
      {"user-agent", @default_user_agent},
      {"accept", "text/html,application/json,text/plain;q=0.9,*/*;q=0.1"}
    ]

    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.put_new(:headers, default_headers)

    req_options
    |> Keyword.put_new(:compressed, true)
    |> Keyword.put_new(:retry, false)
  end

  defp normalize_fetch_response(url, %Response{status: status}, _max_chars) when status >= 400 do
    {:error,
     %{
       "error_type" => "http_error",
       "message" => "HTTP request failed with status #{status}.",
       "status" => status,
       "url" => url
     }}
  end

  defp normalize_fetch_response(url, %Response{} = response, max_chars) do
    content_type = content_type(response)
    body = response.body
    title = fetch_title(content_type, body)
    description = fetch_description(content_type, body)
    text = fetch_text(content_type, body)
    bytes = fetch_bytes(body)
    {text, truncated?} = truncate_text(text, max_chars)

    {:ok,
     %{
       "url" => url,
       "status" => response.status,
       "content_type" => content_type,
       "bytes" => bytes
     }
     |> maybe_put("title", title)
     |> maybe_put("description", description)
     |> maybe_put("text", text)
     |> maybe_put("truncated", truncated?)}
  end

  defp validate_url(""), do: {:error, invalid_input("URL must be a non-empty string.")}

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        :ok

      _uri ->
        {:error, invalid_input("URL must use the http or https scheme.")}
    end
  end

  defp validate_query(""), do: {:error, invalid_input("Query must be a non-empty string.")}
  defp validate_query(_query), do: :ok

  defp fetch_title(content_type, body) when is_binary(body) do
    cond do
      html_content_type?(content_type) -> html_title(body)
      true -> nil
    end
  end

  defp fetch_title(_content_type, _body), do: nil

  defp fetch_description(content_type, body) when is_binary(body) do
    cond do
      html_content_type?(content_type) -> html_meta_description(body)
      true -> nil
    end
  end

  defp fetch_description(_content_type, _body), do: nil

  defp fetch_text(content_type, body) when is_binary(body) do
    cond do
      html_content_type?(content_type) -> html_to_text(body)
      text_content_type?(content_type) -> normalize_text(body)
      json_content_type?(content_type) -> normalize_text(body)
      xml_content_type?(content_type) -> html_to_text(body)
      printable_text?(body) -> normalize_text(body)
      true -> nil
    end
  end

  defp fetch_text(_content_type, body) when is_map(body) or is_list(body) do
    body
    |> Jason.encode!()
    |> normalize_text()
  end

  defp fetch_text(_content_type, _body), do: nil

  defp fetch_bytes(body) when is_binary(body), do: byte_size(body)

  defp fetch_bytes(body) when is_map(body) or is_list(body) do
    body
    |> Jason.encode!()
    |> byte_size()
  end

  defp fetch_bytes(_body), do: 0

  defp truncate_text(nil, _max_chars), do: {nil, nil}

  defp truncate_text(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      {String.slice(text, 0, max_chars), true}
    else
      {text, false}
    end
  end

  defp content_type(%Response{} = response) do
    response
    |> Response.get_header("content-type")
    |> List.first()
    |> case do
      nil -> "application/octet-stream"
      value -> String.downcase(value)
    end
  end

  defp html_content_type?(content_type) do
    String.contains?(content_type, "text/html") or
      String.contains?(content_type, "application/xhtml+xml")
  end

  defp text_content_type?(content_type), do: String.starts_with?(content_type, "text/")
  defp json_content_type?(content_type), do: String.contains?(content_type, "json")
  defp xml_content_type?(content_type), do: String.contains?(content_type, "xml")

  defp html_title(html) do
    html
    |> regex_capture(~r/<title[^>]*>(.*?)<\/title>/is)
    |> normalize_text()
    |> blank_to_nil()
  end

  defp html_meta_description(html) do
    html
    |> regex_capture(~r/<meta[^>]+name=["']description["'][^>]+content=["'](.*?)["'][^>]*>/is)
    |> normalize_text()
    |> blank_to_nil()
  end

  defp html_to_text(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<noscript\b[^>]*>.*?<\/noscript>/is, " ")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(
      ~r/<\/(p|div|section|article|aside|header|footer|li|ul|ol|h[1-6]|table|tr)>/i,
      "\n"
    )
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_html_entities()
    |> normalize_text()
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(text) when is_binary(text) do
    text
    |> decode_html_entities()
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/[^\S\n]+/, " ")
    |> String.replace(~r/\n[ \t]+/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_text(_text), do: nil

  defp printable_text?(text) when is_binary(text) do
    String.valid?(text) and String.printable?(text)
  end

  defp normalize_search_result(result) when is_map(result) do
    result = stringify_keys(result)
    title = result["title"] |> normalize_text() |> blank_to_nil()
    url = result["url"] |> normalize_text() |> blank_to_nil()
    snippet = result["snippet"] |> normalize_text() |> blank_to_nil()

    if is_binary(title) and is_binary(url) do
      %{}
      |> Map.put("title", title)
      |> Map.put("url", url)
      |> maybe_put("snippet", snippet)
    end
  end

  defp normalize_search_result(_result), do: nil

  defp invalid_input(message) do
    %{
      "error_type" => "invalid_input",
      "message" => message
    }
  end

  defp normalize_error_map(error, default_error_type) do
    error
    |> stringify_keys()
    |> Map.put_new("error_type", default_error_type)
    |> Map.put_new("message", default_error_message(error))
  end

  defp base_error_details(error, default_error_type) do
    %{
      "error_type" => classify_http_error(error, default_error_type),
      "message" => error_message(error)
    }
  end

  defp classify_http_error(%Req.TransportError{reason: :timeout}, _default_error_type),
    do: "network_timeout"

  defp classify_http_error(%Req.TransportError{}, _default_error_type), do: "network_error"
  defp classify_http_error(%Req.HTTPError{}, _default_error_type), do: "http_error"
  defp classify_http_error(_error, default_error_type), do: default_error_type

  defp error_message(%{message: message}) when is_binary(message) and message != "", do: message
  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error) when is_binary(error) and error != "", do: error
  defp error_message(error), do: inspect(error)

  defp default_error_message(error), do: error_message(error)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp regex_capture(value, regex) when is_binary(value) do
    case Regex.run(regex, value, capture: :all_but_first) do
      [capture | _rest] -> capture
      _other -> nil
    end
  end

  defp regex_capture(_value, _regex), do: nil

  defp decode_html_entities(nil), do: nil

  defp decode_html_entities(value) when is_binary(value) do
    value
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(value) do
    Regex.replace(~r/&#(x?[0-9A-Fa-f]+);/, value, fn _match, codepoint ->
      try do
        codepoint =
          case String.starts_with?(codepoint, "x") do
            true ->
              codepoint
              |> String.slice(1, String.length(codepoint) - 1)
              |> String.to_integer(16)

            false ->
              String.to_integer(codepoint)
          end

        <<codepoint::utf8>>
      rescue
        _error -> ""
      end
    end)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end

defmodule JidoManagedAgents.Sessions.RuntimeWeb.SearchAdapter do
  @moduledoc false

  @callback search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
end

defmodule JidoManagedAgents.Sessions.RuntimeWeb.DuckDuckGoAdapter do
  @moduledoc false

  @behaviour JidoManagedAgents.Sessions.RuntimeWeb.SearchAdapter

  alias JidoManagedAgents.Sessions.RuntimeWeb
  alias Req.Response

  @base_url "https://html.duckduckgo.com/html/"
  @user_agent "jido_managed_agents/0.1"

  @impl true
  def search(query, opts) when is_binary(query) do
    limit = Keyword.fetch!(opts, :limit)
    req_options = search_req_options(opts)
    base_url = Keyword.get(opts, :base_url, @base_url)

    case Req.request(
           Keyword.merge([method: :get, url: base_url, params: [q: query]], req_options)
         ) do
      {:ok, %Response{} = response} -> normalize_response(response, limit)
      {:error, error} -> {:error, RuntimeWeb.normalize_http_error(error)}
    end
  end

  defp search_req_options(opts) do
    default_headers = [
      {"user-agent", @user_agent},
      {"accept", "text/html;q=1.0,*/*;q=0.1"}
    ]

    opts
    |> Keyword.get(:req_options, [])
    |> Keyword.put_new(:headers, default_headers)
    |> Keyword.put_new(:compressed, true)
    |> Keyword.put_new(:retry, false)
  end

  defp normalize_response(%Response{status: status}, _limit) when status >= 400 do
    {:error,
     %{
       "error_type" => "http_error",
       "message" => "Search request failed with status #{status}.",
       "status" => status
     }}
  end

  defp normalize_response(%Response{body: body}, limit) when is_binary(body) do
    {:ok, parse_results(body, limit)}
  end

  defp normalize_response(%Response{}, _limit) do
    {:error,
     %{
       "error_type" => "search_error",
       "message" => "Search response body was not text."
     }}
  end

  defp parse_results(body, limit) do
    body
    |> Regex.split(~r/(?=<a[^>]*class="[^"]*(?:result__a|result-link)[^"]*")/i)
    |> Enum.drop(1)
    |> Enum.map(&parse_result_segment/1)
    |> Enum.reject(&is_nil/1)
    |> RuntimeWeb.normalize_search_results(limit)
  end

  defp parse_result_segment(segment) do
    with [href, title] <-
           Regex.run(
             ~r/<a[^>]*class="[^"]*(?:result__a|result-link)[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/is,
             segment,
             capture: :all_but_first
           ) do
      snippet =
        case Regex.run(
               ~r/class="[^"]*(?:result__snippet|result-snippet)[^"]*"[^>]*>(.*?)<\/(?:a|td|div|span)>/is,
               segment,
               capture: :all_but_first
             ) do
          [capture | _rest] -> capture
          _other -> nil
        end

      %{
        "title" => title,
        "url" => decode_search_url(href),
        "snippet" => snippet
      }
    end
  end

  defp decode_search_url(href) do
    normalized_href =
      href
      |> String.replace("&amp;", "&")
      |> String.trim()
      |> case do
        "//" <> rest -> "https://" <> rest
        "/" <> _rest = value -> "https://html.duckduckgo.com" <> value
        value -> value
      end

    uri =
      normalized_href
      |> URI.parse()

    query_params =
      case uri.query do
        nil -> %{}
        query -> URI.decode_query(query)
      end

    case query_params do
      %{"uddg" => target} -> target
      _other when is_binary(uri.scheme) -> URI.to_string(uri)
      _other -> normalized_href
    end
  rescue
    _error -> href
  end
end
