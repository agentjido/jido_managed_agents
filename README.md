# JidoManagedAgents

## Status And Expectations: April 10, 2026, 5:00 p.m. CT

This repository is being released in public very early.

As of Friday, April 10, 2026 at 5:00 p.m. Central Time, Anthropic's Claude Managed Agents public materials are roughly 48 hours old. I wanted to respond quickly with a Jido-based alternative that the community can run, inspect, critique, and help build in the open.

This is pre-alpha code. I put together a plan, built an end-to-end first implementation, and shipped it before the normal QA, hardening, and polish cycle I would usually require for a public release. I would not normally release code in this state.

I am releasing it anyway because managed agents are an active topic right now, and I think it is more useful for the community to react to a working first pass than to wait for a quieter and more polished launch. This initial version should be treated as exactly that: an initial version.

Set expectations accordingly:

- the current codebase has not been QA'd to the standard I expect for a normal release
- rough edges, missing safeguards, and incomplete UX are expected in this first pass
- the README will be the primary place for status notes, communication, and build-in-public updates in the near term
- quality, tests, docs, and operator experience should improve in public from here

Jido has a commitment to quality as the ecosystem grows. The point of releasing this early is not to lower that bar. It is to let the community watch the bar get raised in real time and contribute to that process. If you want to help move this from pre-alpha prototype to a credible open source managed-agents platform, PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

`JidoManagedAgents` is a Phoenix application that packages a local managed-agents stack behind an Anthropic-shaped `/v1` API, an authenticated dashboard, seeded demo data, and runnable example assets.

The quickest way to explore it is:

```bash
mix setup
mix phx.server
```

`mix setup` seeds a demo user plus example agents, environments, a vault, a credential, and archived sessions that make the dashboard useful immediately.

## Quickstart

### 1. Start the app

```bash
mix setup
mix phx.server
```

Open <http://localhost:4000>.

### 2. Sign in or create a user

You have two supported local paths:

- Use the seeded demo account at <http://localhost:4000/sign-in>
  - email: `demo@example.com`
  - password: `demo-pass-1234`
- Or create your own browser user at <http://localhost:4000/register>

### 3. Create an API key

Generate a local `/v1` API key for any existing user:

```bash
mix run examples/scripts/create_api_key.exs --email demo@example.com
export JMA_API_KEY=PASTE_THE_PRINTED_KEY_HERE
```

### 4. Import an example agent and create an environment

Import one of the sample `*.agent.yaml` definitions:

```bash
mix run examples/scripts/import_agent_yaml.exs \
  --email demo@example.com \
  examples/agents/coding-assistant.agent.yaml
```

Copy the printed `Agent ID` into `AGENT_ID`.

Create an environment from the example payload:

```bash
curl -sS http://127.0.0.1:4000/v1/environments \
  -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: $JMA_API_KEY" \
  -d @examples/environments/restricted-cloud.environment.json
```

Copy the returned `id` into `ENVIRONMENT_ID`.

If you want the unrestricted Anthropic-compatible networking shape instead, use [`examples/environments/unrestricted-cloud.environment.json`](examples/environments/unrestricted-cloud.environment.json).

### 5. Configure a vault and MCP credential

Create a vault:

```bash
curl -sS http://127.0.0.1:4000/v1/vaults \
  -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: $JMA_API_KEY" \
  -d @examples/requests/demo-vault.create.json
```

Copy the returned `id` into `VAULT_ID`.

Create a demo static-bearer MCP credential inside that vault:

```bash
curl -sS http://127.0.0.1:4000/v1/vaults/$VAULT_ID/credentials \
  -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: $JMA_API_KEY" \
  -d @examples/requests/linear-static-bearer.credential.create.json
```

### 6. Start a session

Create the session:

```bash
curl -sS http://127.0.0.1:4000/v1/sessions \
  -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: $JMA_API_KEY" \
  -d "{\"agent\":\"$AGENT_ID\",\"environment_id\":\"$ENVIRONMENT_ID\",\"title\":\"OSS Walkthrough\",\"vault_ids\":[\"$VAULT_ID\"]}"
```

Copy the returned `id` into `SESSION_ID`.

Append the first user message:

```bash
curl -sS http://127.0.0.1:4000/v1/sessions/$SESSION_ID/events \
  -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: $JMA_API_KEY" \
  -d @examples/requests/user-message.event.json
```

### 7. Stream events and run the local session

In terminal A, open the stream:

```bash
curl -N http://127.0.0.1:4000/v1/sessions/$SESSION_ID/stream \
  -H "accept: text/event-stream" \
  -H "x-api-key: $JMA_API_KEY"
```

In terminal B, invoke the local runtime:

```bash
mix run examples/scripts/run_session.exs --email demo@example.com $SESSION_ID
```

The stream replays persisted events and then stays open for live updates. Stop it with `Ctrl-C` when you have seen enough.

### 8. Use the dashboard

The authenticated dashboard lives under `/console`:

- `/console/agents/new`: create or edit agents, view API/YAML previews, and launch a local run inline
- `/console/environments`: manage reusable environment templates
- `/console/vaults`: manage vaults and write-only credentials
- `/console/sessions`: inspect timelines, raw events, tool activity, and thread traces

The seeded demo data already includes archived happy-path and threaded sessions so `/console/sessions` is populated on a fresh clone.

## Examples

The full example asset index is in [`examples/README.md`](examples/README.md).

- `examples/agents/`: sample `*.agent.yaml` files
- `examples/environments/`: reusable environment payloads
- `examples/requests/`: curl-ready JSON payloads
- `examples/env/llm-providers.env.example`: optional provider env vars
- `examples/scripts/`: helper entrypoints for API keys, YAML import, and local session execution

## Compatibility

### Compatibility goals

- `/v1` uses `x-api-key` authentication and Anthropic-style list/error envelopes for local clients.
- Agent definitions import from and export to Anthropic-compatible `*.agent.yaml` files.
- Environment payloads intentionally follow Anthropic's managed-environment config shape.
- Session resources, event resources, vaults, and credentials are scoped per local user and persist durably in Postgres.
- The dashboard mirrors the Console workflow: create resources, run a session, then inspect traces.

### Intentional divergences from Anthropic's hosted product

- This repository is a self-hosted Phoenix application, not a hosted control plane.
- Browser users and API keys are local Ash authentication resources, not Anthropic account primitives.
- Sessions execute through the local supervised Jido runtime.
- There is no hosted `/v1` run endpoint in this repo today. Use the dashboard runner or [`examples/scripts/run_session.exs`](examples/scripts/run_session.exs) to execute persisted session input locally.
- The current `/v1/environments` surface only accepts `config.type = "cloud"` and `config.networking.type = "restricted" | "unrestricted"`.
- MCP credentials are stored in local vault records with write-only secret behavior instead of provider-managed secret stores.
- The UI intentionally follows Anthropic's flow, not Anthropic branding.

## Provider configuration

Real provider-backed runs need credentials in the environment:

- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`

Use [`examples/env/llm-providers.env.example`](examples/env/llm-providers.env.example) as the starting point. If the app is not reachable at `http://127.0.0.1:$PORT`, set `JIDO_MANAGED_AGENTS_MCP_BASE_URL` as well.

## Jido stack

This project is configured with:

- `jido` for the supervised agent runtime
- `jido_ai` for tool-using AI agents
- `jido_mcp` for exposing and consuming MCP tools
- `jido_workspace` for per-agent files, snapshots, and shell sessions
- `ash_jido` for generating `Jido.Action` modules from Ash resources

The app exposes an MCP endpoint at <http://localhost:4000/mcp> and includes a local example tool published through `JidoManagedAgents.MCP.Server`.

Authentication and authorization stay Ash-native:

- `User` actors use a small v1 role model: `member` and `platform_admin`
- owner-scoped resources rely on `Ash.Policy.Authorizer` policies instead of controller branches
- API keys authenticate as their owning user, so they inherit that user's permissions

## API surfaces

- `/v1`: Anthropic-style local API clients and examples
- `/api/json`: internal Ash JSON:API surface for Ash-oriented workflows
- `/mcp`: local MCP endpoint

`/v1` accepts optional `anthropic-version` and `anthropic-beta` compatibility headers. `/api/json` is intended for internal tooling and may expose different media types and payload conventions than `/v1`.

## Architecture notes

The platform foundation for domains, ownership, Postgres conventions, AshCloak/Cloak secret infrastructure, and normalized-vs-embedded Ash modeling lives in [`docs/ash_platform_architecture.md`](docs/ash_platform_architecture.md). The code-level source of truth for those decisions is `JidoManagedAgents.Platform.Architecture`.
