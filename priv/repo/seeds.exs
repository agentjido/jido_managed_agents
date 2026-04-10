summary = JidoManagedAgents.OSSExample.seed!()

IO.puts("""
Seeded OSS demo data.

Demo user:
  email: #{summary.user.email}
  password: #{JidoManagedAgents.OSSExample.demo_user_password()}

Imported agents:
#{Enum.map_join(summary.agents, "\n", fn agent -> "  - #{agent.name} (v#{agent.latest_version.version})" end)}

Environment:
  #{summary.environment.name}

Vault:
  #{summary.vault.name}

Sessions:
#{Enum.map_join(summary.sessions, "\n", fn session -> "  - #{session.title}" end)}

Generate an API key:
  mix run examples/scripts/create_api_key.exs --email #{summary.user.email}
""")
