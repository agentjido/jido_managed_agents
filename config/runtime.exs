import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/jido_managed_agents start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint, server: true
end

default_port = if config_env() == :test, do: "4002", else: "4000"
endpoint_port = String.to_integer(System.get_env("PORT", default_port))

mcp_base_url =
  System.get_env(
    "JIDO_MANAGED_AGENTS_MCP_BASE_URL",
    if(config_env() == :test,
      do: "http://127.0.0.1:4101",
      else: "http://127.0.0.1:#{endpoint_port}"
    )
  )

default_cloak_key = fn namespace ->
  :crypto.hash(:sha256, namespace)
  |> Base.encode64()
end

{cloak_key, cloak_key_source} =
  case {config_env(), System.get_env("JIDO_MANAGED_AGENTS_CLOAK_KEY")} do
    {_, key} when is_binary(key) and key != "" ->
      {key, :environment}

    {:dev, _} ->
      {default_cloak_key.("jido_managed_agents/dev/cloak"), :development_fallback}

    {:test, _} ->
      {default_cloak_key.("jido_managed_agents/test/cloak"), :test_fallback}

    {:prod, _} ->
      raise """
      environment variable JIDO_MANAGED_AGENTS_CLOAK_KEY is missing.
      Set it to a Base64-encoded 32-byte key before booting production.
      For example: openssl rand -base64 32
      """
  end

config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint, http: [port: endpoint_port]

config :jido_managed_agents, :secret_encryption,
  env_var: "JIDO_MANAGED_AGENTS_CLOAK_KEY",
  key: cloak_key,
  source: cloak_key_source

config :req_llm,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY")

config :jido_mcp, :endpoints,
  managed_agents: %{
    transport: {:streamable_http, [base_url: mcp_base_url]},
    client_info: %{name: "jido_managed_agents", version: "0.1.0"},
    protocol_version: "2025-03-26",
    capabilities: %{},
    timeouts: %{request_ms: 30_000}
  }

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :jido_managed_agents, JidoManagedAgents.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :jido_managed_agents, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :jido_managed_agents,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :jido_managed_agents, JidoManagedAgents.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
