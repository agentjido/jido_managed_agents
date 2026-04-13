ExUnit.start(exclude: [playwright: true])
Ecto.Adapters.SQL.Sandbox.mode(JidoManagedAgents.Repo, :manual)

browser_tests_enabled? = System.get_env("PHX_PLAYWRIGHT") in ~w(1 true)

if browser_tests_enabled? do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, JidoManagedAgentsWeb.Endpoint.url())
end
