defmodule JidoManagedAgents.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JidoManagedAgentsWeb.Telemetry,
      JidoManagedAgents.Vault,
      JidoManagedAgents.Repo,
      {DNSCluster,
       query: Application.get_env(:jido_managed_agents, :dns_cluster_query) || :ignore},
      JidoManagedAgents.Jido,
      {Task.Supervisor, name: JidoManagedAgents.TaskSupervisor},
      JidoManagedAgents.Sessions.RuntimeMCP.EndpointPool,
      {Phoenix.PubSub, name: JidoManagedAgents.PubSub},
      Anubis.Server.Registry,
      {JidoManagedAgents.MCP.Server, transport: {:streamable_http, [start: true]}},
      # Start a worker by calling: JidoManagedAgents.Worker.start_link(arg)
      # {JidoManagedAgents.Worker, arg},
      # Start to serve requests, typically the last entry
      JidoManagedAgentsWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :jido_managed_agents]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: JidoManagedAgents.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JidoManagedAgentsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
