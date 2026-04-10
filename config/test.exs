import Config

config :jido_managed_agents, token_signing_secret: "PDTLd5YAOU2S4eWiEWpu/ddZJiAt2xgl"
config :bcrypt_elixir, log_rounds: 1

config :ash,
  policies: [show_policy_breakdowns?: true],
  disable_async?: true,
  warn_on_transaction_hooks?: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :jido_managed_agents, JidoManagedAgents.Repo,
  username: "postgres",
  password: "postgres",
  socket_dir: System.get_env("JIDO_MANAGED_AGENTS_DB_SOCKET_DIR"),
  hostname: "localhost",
  database: "jido_managed_agents_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :jido_managed_agents, JidoManagedAgentsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "G1k53NIk7jl3zawwM0J23eTufDpp5qSWnbzxXwtBKKv4ml4TYUPKYRQRVv51+6Z1",
  server: false

# In test we don't send emails
config :jido_managed_agents, JidoManagedAgents.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
