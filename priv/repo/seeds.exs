summary = JidoManagedAgents.OSSExample.seed!()

session_status = fn session ->
  cond do
    session.archived_at -> "archived"
    get_in(session.stop_reason || %{}, ["type"]) == "requires_action" -> "needs input"
    true -> to_string(session.status)
  end
end

IO.puts("""
Seeded demo workspace data.

Demo user:
  email: #{summary.user.email}
  password: #{JidoManagedAgents.OSSExample.demo_user_password()}

Imported agents:
#{Enum.map_join(summary.agents, "\n", fn agent -> "  - #{agent.name} (v#{agent.latest_version.version})" end)}

Environment:
  #{summary.environment.name}

Vaults:
#{Enum.map_join(summary.vaults, "\n", fn vault -> "  - #{vault.name}" end)}

Credentials:
#{Enum.map_join(summary.credentials, "\n", fn credential ->
  display_name = get_in(credential.metadata || %{}, ["__credential_surface__", "display_name"]) || credential.mcp_server_url

  "  - #{display_name} (#{credential.type} · #{credential.mcp_server_url})"
end)}

Sessions:
#{Enum.map_join(summary.sessions, "\n", fn session -> "  - #{session.title} [#{session_status.(session)}]" end)}

Generate an API key:
  mix run examples/scripts/create_api_key.exs --email #{summary.user.email}
""")
