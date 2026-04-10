defmodule JidoManagedAgents.Integrations.CredentialDefinition do
  @moduledoc """
  Normalization and serialization helpers for `/v1` credential payloads.
  """

  alias JidoManagedAgents.Integrations.Credential

  @surface_metadata_key "__credential_surface__"

  @spec normalize_create_payload(map()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_create_payload(params) when is_map(params) do
    params = stringify_top_level_keys(params)

    with {:ok, auth} <- extract_auth(params),
         {:ok, type} <- normalize_type(Map.get(auth, "type"), "auth.type"),
         {:ok, public_metadata} <-
           map_value(Map.get(params, "metadata"), default: %{}, field: "metadata"),
         {:ok, surface, attrs} <- normalize_create_auth(type, auth) do
      surface =
        if Map.has_key?(params, "display_name") do
          Map.put(surface, "display_name", Map.get(params, "display_name"))
        else
          surface
        end

      {:ok,
       attrs
       |> Map.put(:type, type)
       |> Map.put(:metadata, build_metadata(public_metadata, merge_surface(%{}, surface)))}
    end
  end

  def normalize_create_payload(_params) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec normalize_update_payload(map(), Credential.t()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}}
  def normalize_update_payload(params, %Credential{} = credential) when is_map(params) do
    params = stringify_top_level_keys(params)
    current_public_metadata = public_metadata(credential.metadata)
    current_surface = surface_metadata(credential.metadata)

    with {:ok, auth} <- extract_optional_auth(params),
         :ok <- validate_type_update(auth, credential.type),
         :ok <- reject_immutable_updates(auth, credential.type),
         {:ok, public_metadata} <- merge_public_metadata(params, current_public_metadata),
         {:ok, surface, attrs} <- normalize_update_auth(credential.type, auth) do
      surface =
        if Map.has_key?(params, "display_name") do
          Map.put(surface, "display_name", Map.get(params, "display_name"))
        else
          surface
        end

      metadata =
        case metadata_changed?(params, surface) do
          true -> build_metadata(public_metadata, merge_surface(current_surface, surface))
          false -> nil
        end

      {:ok,
       attrs
       |> maybe_put(:metadata, metadata)
       |> drop_nil_values()}
    end
  end

  def normalize_update_payload(_params, _credential) do
    {:error, {:invalid_request, "Request body must be a JSON object."}}
  end

  @spec serialize_credential(Credential.t()) :: map()
  def serialize_credential(%Credential{} = credential) do
    surface = surface_metadata(credential.metadata)

    %{
      id: credential.id,
      type: "credential",
      vault_id: credential.vault_id,
      display_name: surface["display_name"],
      metadata: public_metadata(credential.metadata),
      auth: serialize_auth(credential, surface),
      created_at: credential.created_at,
      updated_at: credential.updated_at
    }
    |> drop_nil_values()
  end

  defp normalize_create_auth(:static_bearer, auth) do
    with {:ok, mcp_server_url} <-
           required_string(auth, "mcp_server_url", prefix: "auth."),
         {:ok, token} <- required_bearer_token(auth, "auth") do
      {:ok, surface_from_auth(auth, nil), %{mcp_server_url: mcp_server_url, access_token: token}}
    end
  end

  defp normalize_create_auth(:mcp_oauth, auth) do
    with {:ok, mcp_server_url} <-
           required_string(auth, "mcp_server_url", prefix: "auth."),
         {:ok, access_token} <- required_string(auth, "access_token", prefix: "auth."),
         {:ok, refresh} <- optional_map(Map.get(auth, "refresh"), "auth.refresh"),
         {:ok, token_endpoint} <-
           optional_string(
             Map.get(auth, "token_endpoint") || value_from_map(refresh, "token_endpoint"),
             "auth.refresh.token_endpoint"
           ),
         {:ok, client_id} <-
           optional_string(
             Map.get(auth, "client_id") || value_from_map(refresh, "client_id"),
             "auth.refresh.client_id"
           ),
         {:ok, refresh_token} <-
           optional_string(
             Map.get(auth, "refresh_token") || value_from_map(refresh, "refresh_token"),
             "auth.refresh.refresh_token"
           ),
         {:ok, token_endpoint_auth} <-
           optional_map(
             value_from_map(refresh, "token_endpoint_auth"),
             "auth.refresh.token_endpoint_auth"
           ),
         {:ok, client_secret} <-
           optional_string(
             Map.get(auth, "client_secret") ||
               value_from_map(token_endpoint_auth, "client_secret"),
             "auth.refresh.token_endpoint_auth.client_secret"
           ) do
      {:ok, surface_from_auth(auth, refresh),
       %{
         mcp_server_url: mcp_server_url,
         token_endpoint: token_endpoint,
         client_id: client_id,
         access_token: access_token,
         refresh_token: refresh_token,
         client_secret: client_secret
       }}
    end
  end

  defp normalize_update_auth(:static_bearer, auth) do
    token =
      cond do
        is_map(auth) and Map.has_key?(auth, "token") -> Map.get(auth, "token")
        is_map(auth) and Map.has_key?(auth, "access_token") -> Map.get(auth, "access_token")
        true -> nil
      end

    with {:ok, access_token} <- optional_string(token, "auth.token") do
      {:ok, surface_from_auth(auth, nil), %{access_token: access_token}}
    end
  end

  defp normalize_update_auth(:mcp_oauth, auth) do
    refresh = if is_map(auth), do: value_from_map(auth, "refresh"), else: nil

    with {:ok, refresh} <- optional_map(refresh, "auth.refresh"),
         {:ok, access_token} <-
           optional_string(value_from_map(auth, "access_token"), "auth.access_token"),
         {:ok, refresh_token} <-
           optional_string(
             value_from_map(auth, "refresh_token") || value_from_map(refresh, "refresh_token"),
             "auth.refresh.refresh_token"
           ),
         {:ok, token_endpoint_auth} <-
           optional_map(
             value_from_map(refresh, "token_endpoint_auth"),
             "auth.refresh.token_endpoint_auth"
           ),
         {:ok, client_secret} <-
           optional_string(
             value_from_map(auth, "client_secret") ||
               value_from_map(token_endpoint_auth, "client_secret"),
             "auth.refresh.token_endpoint_auth.client_secret"
           ) do
      {:ok, surface_from_auth(auth, refresh),
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         client_secret: client_secret
       }}
    end
  end

  defp serialize_auth(%Credential{type: :static_bearer} = credential, _surface) do
    %{
      type: "static_bearer",
      mcp_server_url: credential.mcp_server_url
    }
  end

  defp serialize_auth(%Credential{type: :mcp_oauth} = credential, surface) do
    refresh =
      %{}
      |> maybe_put(:token_endpoint, credential.token_endpoint)
      |> maybe_put(:client_id, credential.client_id)
      |> maybe_put(:scope, get_in(surface, ["refresh", "scope"]))
      |> maybe_put_nested(:token_endpoint_auth, %{
        type: get_in(surface, ["refresh", "token_endpoint_auth", "type"])
      })
      |> drop_nil_values()

    %{
      type: "mcp_oauth",
      mcp_server_url: credential.mcp_server_url,
      expires_at: surface["expires_at"],
      refresh: if(map_size(refresh) == 0, do: nil, else: refresh)
    }
    |> drop_nil_values()
  end

  defp extract_auth(params) do
    case Map.get(params, "auth") do
      nil -> {:ok, params}
      value when is_map(value) -> {:ok, stringify_top_level_keys(value)}
      _other -> {:error, {:invalid_request, "auth must be an object."}}
    end
  end

  defp extract_optional_auth(params) do
    case Map.get(params, "auth") do
      nil -> {:ok, params}
      value when is_map(value) -> {:ok, stringify_top_level_keys(value)}
      _other -> {:error, {:invalid_request, "auth must be an object."}}
    end
  end

  defp normalize_type(nil, field) do
    {:error, {:invalid_request, "#{field} is required."}}
  end

  defp normalize_type(value, _field) when value in [:mcp_oauth, "mcp_oauth"],
    do: {:ok, :mcp_oauth}

  defp normalize_type(value, _field) when value in [:static_bearer, "static_bearer"],
    do: {:ok, :static_bearer}

  defp normalize_type(_value, field) do
    {:error, {:invalid_request, "#{field} must be \"mcp_oauth\" or \"static_bearer\"."}}
  end

  defp validate_type_update(auth, type) do
    case value_from_map(auth, "type") do
      nil ->
        :ok

      value ->
        case normalize_type(value, "auth.type") do
          {:ok, ^type} ->
            :ok

          {:ok, _other} ->
            {:error, {:invalid_request, "auth.type cannot be changed after credential creation."}}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp reject_immutable_updates(auth, :static_bearer) do
    with :ok <- reject_present_field(auth, "mcp_server_url", "auth.mcp_server_url"),
         :ok <- reject_present_field(auth, "token_endpoint", "auth.refresh.token_endpoint"),
         :ok <- reject_present_field(auth, "client_id", "auth.refresh.client_id"),
         :ok <- reject_present_field(auth, "refresh", "auth.refresh") do
      :ok
    end
  end

  defp reject_immutable_updates(auth, :mcp_oauth) do
    refresh = value_from_map(auth, "refresh")

    with :ok <- reject_present_field(auth, "mcp_server_url", "auth.mcp_server_url"),
         :ok <- reject_present_field(auth, "token_endpoint", "auth.refresh.token_endpoint"),
         :ok <- reject_present_field(auth, "client_id", "auth.refresh.client_id"),
         :ok <- reject_present_field(refresh, "token_endpoint", "auth.refresh.token_endpoint"),
         :ok <- reject_present_field(refresh, "client_id", "auth.refresh.client_id") do
      :ok
    end
  end

  defp reject_present_field(nil, _field, _message_field), do: :ok

  defp reject_present_field(map, field, message_field) when is_map(map) do
    if Map.has_key?(map, field) do
      {:error,
       {:invalid_request, "#{message_field} cannot be changed after credential creation."}}
    else
      :ok
    end
  end

  defp merge_public_metadata(params, current_public_metadata) do
    if Map.has_key?(params, "metadata") do
      with {:ok, metadata} <- required_map(Map.get(params, "metadata"), "metadata") do
        {:ok, merge_metadata_values(current_public_metadata, metadata)}
      end
    else
      {:ok, current_public_metadata}
    end
  end

  defp required_bearer_token(auth, prefix) do
    case value_from_map(auth, "token") || value_from_map(auth, "access_token") do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:invalid_request, "#{prefix}.token is required."}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:invalid_request, "#{prefix}.token is required."}}
    end
  end

  defp surface_from_auth(auth, refresh) do
    %{}
    |> maybe_put("display_name", value_from_map(auth, "display_name"))
    |> maybe_put("expires_at", value_from_map(auth, "expires_at"))
    |> maybe_put_nested("refresh", %{
      "scope" => value_from_map(refresh, "scope"),
      "token_endpoint_auth" => %{
        "type" => value_from_map(value_from_map(refresh, "token_endpoint_auth"), "type")
      }
    })
    |> compact_map()
  end

  defp build_metadata(public_metadata, surface) do
    public_metadata =
      public_metadata
      |> stringify_keys_deep()
      |> Map.delete(@surface_metadata_key)

    surface = compact_map(surface)

    if map_size(surface) == 0 do
      public_metadata
    else
      Map.put(public_metadata, @surface_metadata_key, surface)
    end
  end

  defp public_metadata(metadata) do
    metadata
    |> stringify_keys_deep()
    |> Map.delete(@surface_metadata_key)
  end

  defp surface_metadata(metadata) do
    metadata
    |> stringify_keys_deep()
    |> Map.get(@surface_metadata_key, %{})
  end

  defp metadata_changed?(params, surface) do
    Map.has_key?(params, "metadata") or map_size(surface) > 0
  end

  defp merge_surface(current_surface, incoming_surface) do
    current_surface
    |> stringify_keys_deep()
    |> do_merge_surface(incoming_surface)
    |> compact_map()
  end

  defp do_merge_surface(current, incoming) when map_size(incoming) == 0, do: current

  defp do_merge_surface(current, incoming) do
    Enum.reduce(incoming, current, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_map(value) ->
        current_value =
          case Map.get(acc, key) do
            existing when is_map(existing) -> existing
            _other -> %{}
          end

        merged = do_merge_surface(current_value, value)

        if map_size(merged) == 0 do
          Map.delete(acc, key)
        else
          Map.put(acc, key, merged)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp merge_metadata_values(current, incoming) do
    incoming
    |> stringify_top_level_keys()
    |> Enum.reject(fn {key, _value} -> key == @surface_metadata_key end)
    |> Enum.reduce(current, fn
      {key, ""}, metadata -> Map.delete(metadata, key)
      {key, value}, metadata -> Map.put(metadata, key, stringify_keys_deep(value))
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_nested(map, key, nested) when is_map(nested) do
    nested = compact_map(nested)

    if map_size(nested) == 0 do
      map
    else
      Map.put(map, key, nested)
    end
  end

  defp value_from_map(nil, _key), do: nil
  defp value_from_map(map, key) when is_map(map), do: Map.get(map, key)
  defp value_from_map(_value, _key), do: nil

  defp required_string(params, field, opts) do
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

  defp optional_map(nil, _field), do: {:ok, nil}
  defp optional_map(value, _field) when is_map(value), do: {:ok, stringify_top_level_keys(value)}

  defp optional_map(_value, field) do
    {:error, {:invalid_request, "#{field} must be an object."}}
  end

  defp required_map(nil, field), do: {:error, {:invalid_request, "#{field} is required."}}
  defp required_map(value, _field) when is_map(value), do: {:ok, value}

  defp required_map(_value, field) do
    {:error, {:invalid_request, "#{field} must be an object."}}
  end

  defp map_value(nil, opts), do: {:ok, Keyword.fetch!(opts, :default)}
  defp map_value(value, _opts) when is_map(value), do: {:ok, value}

  defp map_value(_value, opts) do
    {:error, {:invalid_request, "#{Keyword.fetch!(opts, :field)} must be an object."}}
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_map(value) ->
        compacted = compact_map(value)

        if map_size(compacted) == 0 do
          acc
        else
          Map.put(acc, key, compacted)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp drop_nil_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp present_string?(value) when is_binary(value) do
    String.trim(value) != ""
  end

  defp present_string?(_value), do: false

  defp stringify_top_level_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys_deep(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys_deep(value)} end)
  end

  defp stringify_keys_deep(values) when is_list(values) do
    Enum.map(values, &stringify_keys_deep/1)
  end

  defp stringify_keys_deep(value), do: value
end
