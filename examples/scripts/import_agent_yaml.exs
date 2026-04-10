{opts, args, _invalid} = OptionParser.parse!(System.argv(), strict: [email: :string])

email =
  opts[:email] ||
    raise ArgumentError,
          "usage: mix run examples/scripts/import_agent_yaml.exs --email you@example.com path/to/example.agent.yaml"

path =
  case args do
    [path] -> path
    _other -> raise ArgumentError, "expected exactly one YAML path argument"
  end

agent = JidoManagedAgents.OSSExample.import_agent_yaml!(email, path)

IO.puts("""
Imported #{Path.basename(path)}
Agent ID: #{agent.id}
Latest version: #{agent.latest_version.version}
Name: #{agent.name}
""")
