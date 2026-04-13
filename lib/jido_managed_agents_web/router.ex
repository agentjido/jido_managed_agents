defmodule JidoManagedAgentsWeb.Router do
  use JidoManagedAgentsWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  @sandbox_live_hooks (if Application.compile_env(:jido_managed_agents, :sql_sandbox) do
                         [JidoManagedAgentsWeb.LiveAcceptance]
                       else
                         []
                       end)
  @sandbox_live_no_user_hooks @sandbox_live_hooks ++
                                [{JidoManagedAgentsWeb.LiveUserAuth, :live_no_user}]

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {JidoManagedAgentsWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:load_from_session)
    plug(:set_actor, :user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:load_from_bearer)

    plug(AshAuthentication.Strategy.ApiKey.Plug,
      resource: JidoManagedAgents.Accounts.User,
      # if you want to require an api key to be supplied, set `required?` to true
      required?: false
    )

    plug(:set_actor, :user)
  end

  pipeline :v1_api do
    plug(:accepts, ["json", "event-stream"])
    plug(JidoManagedAgentsWeb.Plugs.CaptureAnthropicHeaders)
    plug(JidoManagedAgentsWeb.Plugs.PrepareV1ApiKey)

    plug(AshAuthentication.Strategy.ApiKey.Plug,
      resource: JidoManagedAgents.Accounts.User,
      on_error: &JidoManagedAgentsWeb.V1.ApiKeyAuthError.on_error/2
    )

    plug(:set_actor, :user)
  end

  scope "/" do
    forward(
      "/mcp",
      Anubis.Server.Transport.StreamableHTTP.Plug,
      Jido.MCP.Server.plug_init_opts(JidoManagedAgents.MCP.Server)
    )
  end

  scope "/", JidoManagedAgentsWeb do
    pipe_through(:browser)

    ash_authentication_live_session :authenticated_routes,
      on_mount_prepend: @sandbox_live_hooks do
      live("/console", OverviewLive, :index)
      live("/console/agents", AgentsLibraryLive, :index)
      live("/console/agents/new", AgentBuilderLive, :new)
      live("/console/agents/:id/edit", AgentBuilderLive, :edit)
      live("/console/agents/:id", AgentDetailLive, :show)
      live("/console/environments", EnvironmentConsoleLive, :index)
      live("/console/environments/:id/edit", EnvironmentConsoleLive, :edit)
      live("/console/sessions", SessionObservabilityLive, :index)
      live("/console/sessions/:id", SessionObservabilityLive, :show)
      live("/console/api-docs", ApiDocsLive, :index)
      live("/console/vaults", VaultConsoleLive, :index)

      live(
        "/console/vaults/:vault_id/credentials/:credential_id/rotate",
        VaultConsoleLive,
        :rotate
      )

      live("/console/vaults/:id", VaultConsoleLive, :show)

      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {JidoManagedAgentsWeb.LiveUserAuth, :live_no_user}
    end
  end

  scope "/api/json" do
    pipe_through([:api])

    forward("/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4
    )

    forward("/", JidoManagedAgentsWeb.AshJsonApiRouter)
  end

  scope "/v1", JidoManagedAgentsWeb.V1 do
    pipe_through([:v1_api])

    post("/agents", AgentController, :create)
    get("/agents", AgentController, :index)
    get("/agents/:id/versions", AgentController, :versions)
    put("/agents/:id", AgentController, :update)
    post("/agents/:id/archive", AgentController, :archive)
    delete("/agents/:id", AgentController, :delete)
    get("/agents/:id", AgentController, :show)

    post("/skills", SkillController, :create)
    get("/skills", SkillController, :index)
    get("/skills/:id/versions", SkillController, :versions)
    get("/skills/:id", SkillController, :show)

    post("/environments", EnvironmentController, :create)
    get("/environments", EnvironmentController, :index)
    put("/environments/:id", EnvironmentController, :update)
    post("/environments/:id/archive", EnvironmentController, :archive)
    delete("/environments/:id", EnvironmentController, :delete)
    get("/environments/:id", EnvironmentController, :show)

    post("/vaults", VaultController, :create)
    get("/vaults", VaultController, :index)
    post("/vaults/:vault_id/credentials", CredentialController, :create)
    get("/vaults/:vault_id/credentials", CredentialController, :index)
    put("/vaults/:vault_id/credentials/:id", CredentialController, :update)
    delete("/vaults/:vault_id/credentials/:id", CredentialController, :delete)
    get("/vaults/:vault_id/credentials/:id", CredentialController, :show)
    delete("/vaults/:id", VaultController, :delete)
    get("/vaults/:id", VaultController, :show)

    post("/sessions", SessionController, :create)
    get("/sessions", SessionController, :index)
    get("/sessions/:id/stream", SessionController, :stream)
    get("/sessions/:id/threads", SessionController, :threads)
    get("/sessions/:id/threads/:thread_id/events", SessionController, :thread_events)
    get("/sessions/:id/threads/:thread_id/stream", SessionController, :thread_stream)
    post("/sessions/:id/events", SessionController, :create_event)
    get("/sessions/:id/events", SessionController, :events)
    post("/sessions/:id/archive", SessionController, :archive)
    delete("/sessions/:id", SessionController, :delete)
    get("/sessions/:id", SessionController, :show)
  end

  scope "/", JidoManagedAgentsWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
    auth_routes(AuthController, JidoManagedAgents.Accounts.User, path: "/auth")
    sign_out_route(AuthController)

    # Remove these if you'd like to use your own authentication views
    sign_in_route(
      register_path: "/register",
      reset_path: "/reset",
      auth_routes_prefix: "/auth",
      on_mount: @sandbox_live_no_user_hooks,
      overrides: [
        JidoManagedAgentsWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
      ]
    )

    # Remove this if you do not want to use the reset password feature
    reset_route(
      auth_routes_prefix: "/auth",
      on_mount: @sandbox_live_hooks,
      overrides: [
        JidoManagedAgentsWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
      ]
    )

    # Remove this if you do not use the confirmation strategy
    confirm_route(JidoManagedAgents.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      on_mount: @sandbox_live_hooks,
      overrides: [
        JidoManagedAgentsWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
      ]
    )

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(JidoManagedAgents.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      on_mount: @sandbox_live_hooks,
      overrides: [
        JidoManagedAgentsWeb.AuthOverrides,
        Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
      ]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", JidoManagedAgentsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:jido_managed_agents, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: JidoManagedAgentsWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
