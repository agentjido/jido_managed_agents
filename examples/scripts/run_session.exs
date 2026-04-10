{opts, args, _invalid} = OptionParser.parse!(System.argv(), strict: [email: :string])

email =
  opts[:email] ||
    raise ArgumentError,
          "usage: mix run examples/scripts/run_session.exs --email you@example.com SESSION_ID"

session_id =
  case args do
    [session_id] -> session_id
    _other -> raise ArgumentError, "expected exactly one SESSION_ID argument"
  end

case JidoManagedAgents.OSSExample.run_session!(session_id, email) do
  {:ok, result} ->
    IO.puts("""
    Session #{session_id} finished with status #{result.session.status}
    Consumed user events: #{Enum.count(result.consumed_events)}
    Emitted events: #{Enum.map_join(result.emitted_events, ", ", & &1.type)}
    """)

  {:error, error} ->
    raise RuntimeError, "session run failed: #{inspect(error)}"
end
