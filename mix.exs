defmodule JidoManagedAgents.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_managed_agents,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() not in [:dev, :test],
      test_coverage: coverage_settings(),
      usage_rules: usage_rules()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {JidoManagedAgents.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        browser_test: :test,
        managed_agent: :dev,
        ma: :dev
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp elixirc_options(:test), do: [ignore_module_conflict: true]
  defp elixirc_options(_), do: []

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Jido - Agent framework core
      {:jido, "~> 2.2", override: true},
      {:jido_action,
       git: "https://github.com/agentjido/jido_action.git",
       ref: "7b2415595aad4834265303b38a3d1928f3461a22",
       override: true},
      {:jido_ai, "~> 2.1"},
      {:jido_mcp,
       git: "https://github.com/agentjido/jido_mcp.git",
       ref: "8cdd6397cd99d9e3c2c1493c1dcd0875b5e27182"},
      {:jido_workspace,
       git: "https://github.com/agentjido/jido_workspace.git",
       ref: "d01bf67e4911fad06a379b41b8e9f74966d73310"},

      # Ash Framework
      {:ash, "~> 3.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_cloak, "~> 0.2.0"},
      {:ash_jido,
       git: "https://github.com/agentjido/ash_jido.git",
       ref: "bdbb02e5de31e8c971baa5b20ab01f826be8b790"},
      {:ash_json_api, "~> 1.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},

      # Phoenix
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:bandit, "~> 1.5"},

      # Database
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},

      # Security & encryption
      {:bcrypt_elixir, "~> 3.0"},
      {:cloak, "~> 1.1"},

      # Frontend assets & UI
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisy_ui_components, "~> 0.9"},

      # Email
      {:swoosh, "~> 1.16"},

      # HTTP & API
      {:req, "~> 0.5"},
      {:open_api_spex, "~> 3.0"},

      # Telemetry & observability
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Utilities
      {:dns_cluster, "~> 0.2.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:picosat_elixir, "~> 0.2"},

      # Dev & test tooling
      {:igniter, "~> 0.7", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.10.0", only: :test, runtime: false},
      {:phoenix_test_playwright, "~> 0.13.0", only: :test, runtime: false},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:usage_rules, "~> 1.0", only: [:dev]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: ["usage_rules:all"],
      skills: [
        location: ".amp/skills",
        build: [
          "ash-framework": [
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
    ]
  end

  defp coverage_settings do
    [
      summary: [threshold: 70],
      ignore_modules: [
        ~r/^Inspect\./,
        ~r/^JidoManagedAgents\..*\.Jido\./
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      ma: ["managed_agent"],
      browser_test: [&run_browser_test/1],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      cover: ["test --cover"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind jido_managed_agents", "esbuild jido_managed_agents"],
      "assets.deploy": [
        "tailwind jido_managed_agents --minify",
        "esbuild jido_managed_agents --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp run_browser_test(args) do
    System.put_env("PHX_PLAYWRIGHT", "1")
    Mix.Task.run("test", ["--only", "playwright" | args])
  end
end
