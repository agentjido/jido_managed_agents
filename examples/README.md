# Examples

This directory backs the OSS quickstart in the root `README.md`.

- `agents/`: Anthropic-compatible `*.agent.yaml` definitions that you can import with `mix run examples/scripts/import_agent_yaml.exs`.
- `environments/`: ready-to-post `/v1/environments` payloads.
- `requests/`: reusable JSON bodies for vault, credential, and event API calls.
- `env/`: optional environment variable examples for real provider-backed runs.
- `scripts/`: helper entrypoints for importing YAML, creating API keys, and running local sessions.
