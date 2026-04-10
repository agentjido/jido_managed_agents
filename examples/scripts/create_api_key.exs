{opts, _args, _invalid} = OptionParser.parse!(System.argv(), strict: [email: :string, days: :integer])

email =
  opts[:email] ||
    raise ArgumentError, "usage: mix run examples/scripts/create_api_key.exs --email you@example.com [--days 30]"

ttl_days = opts[:days] || 30
result = JidoManagedAgents.OSSExample.create_api_key!(email, ttl_days: ttl_days)

IO.puts("""
Created API key for #{result.user.email}
Expires at: #{DateTime.to_iso8601(result.expires_at)}

x-api-key: #{result.plaintext_api_key}

export JMA_API_KEY=#{result.plaintext_api_key}
""")
