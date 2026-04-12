defmodule JidoManagedAgentsWeb.ApiDocsLiveTest do
  use JidoManagedAgentsWeb.ConnCase, async: false

  require Ash.Query

  alias JidoManagedAgents.Accounts
  alias JidoManagedAgents.Accounts.ApiKey

  test "renders the API docs screen and generates API keys", %{conn: conn} do
    %{conn: conn, current_user: user} = register_and_log_in_user(%{conn: conn})

    assert api_key_count(user) == 0

    {:ok, view, html} = live(conn, ~p"/console/api-docs")

    assert html =~ "API Documentation"
    assert html =~ "x-api-key"
    assert has_element?(view, "#api-key-form")
    assert has_element?(view, "a[href='/api/json/swaggerui']")
    assert has_element?(view, "a[href='/api/json/open_api']")
    assert render(view) =~ "/v1/agents"
    assert render(view) =~ "YOUR_API_KEY"

    render_click(element(view, "button[phx-value-resource='Sessions']"))

    assert render(view) =~ "/v1/sessions"
    assert render(view) =~ "environment_id"

    render_submit(element(view, "#api-key-form"), %{"api_key" => %{"ttl_days" => "7"}})

    assert has_element?(view, "#generated-api-key")
    assert api_key_count(user) == 1

    html = render(view)

    refute html =~ "YOUR_API_KEY"
    assert html =~ "jidomanagedagents"
  end

  defp api_key_count(user) do
    ApiKey
    |> Ash.Query.for_read(:read, %{}, actor: user, domain: Accounts)
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!()
    |> length()
  end
end
