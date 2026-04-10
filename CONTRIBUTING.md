# Contributing

Thanks for considering a contribution.

This repository is an open source, vibe-coded prototype for a Jido-based alternative to Anthropic's managed agents. That means two things are true at the same time:

- The project is early, fast-moving, and still rough around the edges.
- Good community contributions can materially change the direction and quality of the system.

If you want to help shape the runtime, dashboard, API compatibility, or operator workflow, PRs are welcome.

## What This Project Is Trying To Be

The target is not a clone for its own sake. The target is a useful, self-hosted managed-agents stack built on Jido primitives with:

- a local `/v1` API that feels familiar to Anthropic-style clients
- a real browser console for agents, environments, vaults, and sessions
- durable session history and observability
- MCP integration for tools and interoperability
- clear security and ownership boundaries around credentials and runtime state

When proposing changes, optimize for that goal. Contributions that make the product more operable, more inspectable, and more coherent are the most valuable.

## Good Contribution Areas

The repo is especially open to help in these areas:

- runtime correctness, supervision, and concurrency behavior
- session observability and trace UX
- Anthropic-compatible import/export and API ergonomics
- environment, vault, and credential workflows
- dashboard polish, navigation, and information architecture
- docs, examples, seeded demo flows, and onboarding
- test coverage around regressions and edge cases

## Before You Start

Read the following first:

- [`README.md`](README.md)
- [`AGENTS.md`](AGENTS.md)
- [`docs/ash_platform_architecture.md`](docs/ash_platform_architecture.md)
- [`examples/README.md`](examples/README.md)

`AGENTS.md` is not just for AI tooling. It captures repo-specific engineering expectations that human contributors should follow too.

## Local Setup

### 1. Install dependencies and initialize the app

```bash
mix setup
```

### 2. Start the application

```bash
mix phx.server
```

Open <http://localhost:4000>.

### 3. Use the seeded demo account

- email: `demo@example.com`
- password: `demo-pass-1234`

### 4. Reset the database when needed

```bash
mix ecto.reset
```

If you are working on Ash resources or migrations, make sure your migration and snapshot state is clean before opening a PR.

## Development Expectations

### Keep changes focused

Small, targeted PRs are easier to review and much less likely to break the product surface. If you want to do a large refactor, open an issue or discussion first so the direction is explicit.

### Preserve the OSS posture

Prefer open source dependencies, examples, and workflows. Avoid introducing paid-only templates, closed integrations, or product assumptions that make the repo less usable to the community.

### Match existing stack choices

- Phoenix for the web layer
- Ash for resources and authorization
- Jido and related packages for runtime behavior
- `Req` for HTTP requests

If you want to introduce a new dependency or framework-level pattern, explain why the current stack is insufficient.

### Add or update tests

Bug fixes and behavioral changes should come with tests whenever practical. If a change is hard to test, explain the gap clearly in the PR.

### Update docs when behavior changes

If your PR changes setup, example flows, API shapes, seeded data, or dashboard behavior, update the relevant docs in the same PR.

### Keep compatibility intentional

This repo intentionally mirrors parts of Anthropic's managed-agents flow, but it is not Anthropic's product. If you change compatibility behavior, document whether the change moves the project closer to or further from that target and why.

## Pre-PR Checklist

Run this before opening a PR:

```bash
mix precommit
```

That alias runs the required compile, format, and test gates for this repo.

If your work touches migrations or Ash snapshots, also verify the generated artifacts are intentional and commit them together.

## UI/UX Contributions

For UI changes, include:

- a short description of the user problem being solved
- screenshots or short recordings for desktop and mobile when the change is visible
- any navigation or copy changes that affect onboarding

This repo needs product-quality operator interfaces, not framework starter pages with renamed labels. Contributions that improve clarity under real debugging conditions are especially useful.

## PR Guidelines

Please include the following in your PR description:

- what changed
- why it changed
- how you verified it
- any follow-up work or known gaps

If your PR changes behavior in a way a maintainer should watch carefully, say that directly. A blunt, technically accurate PR description is better than a vague one.

## Issues and Discussions

If you are not sure whether a change fits, open an issue first with:

- the problem statement
- the current behavior
- the proposed direction
- any compatibility or migration concerns

This is especially helpful for:

- new API surfaces
- major UI rewrites
- authorization changes
- data model changes
- dependency additions

## Review Criteria

PRs are most likely to be accepted when they:

- move the repo toward a credible Jido-based managed-agents alternative
- improve correctness, clarity, or operator usability
- keep the stack coherent
- include tests and docs that match the change
- avoid unnecessary product or architectural sprawl

## Code Of Conduct

Be direct, respectful, and technically rigorous. Assume good intent, but do not hand-wave real engineering concerns.
