---
tracker:
  kind: github
  active_states: [open]
  terminal_states: [closed]
  required_labels: [symphony-ready]
  provider:
    repo: JustinWald/my-symphony
    token: $SYMPHONY_GITHUB_TOKEN
polling:
  interval_ms: 30000
workspace:
  root: /PRIVATE/workspaces/symphony
hooks:
  after_create: |
    /PRIVATE/operator-tools/bootstrap-workspace.sh https://github.com/JustinWald/my-symphony.git REPLACE_WITH_REVIEWED_CI_PASSING_40_CHARACTER_SOURCE_SHA
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
server:
  host: 127.0.0.1
  port: 4687
management:
  repo: JustinWald/my-symphony
  source_repo: /PRIVATE/reviewed-symphony-source
  github_auth_mode: symphony
  symphony_github_token_env: SYMPHONY_GITHUB_TOKEN
  workflow:
    required_checks: [make-all, validate-pr-description, candidate-linux_x86_64]
  delivery_enabled: false
  publish_enabled: false
  audit:
    enabled: false
    draft_prs: false
    codex_binary: /PRIVATE/toolchain/codex
    timeout_seconds: 600
    max_calls_per_week: 1
    proposal_paths:
      - elixir/lib/*
      - elixir/test/*
      - elixir/mix.exs
      - elixir/mix.lock
      - elixir/Makefile
      - .github/workflows/*.yml
      - docs/*
      - README.md
    validation_commands: [[make, -C, elixir, all]]
    validation_readable_paths: [/PRIVATE/toolchain, /PRIVATE/dependency-cache]
---

Work on {{ issue.identifier }}: {{ issue.title }} in this disposable Symphony development workspace.

{{ issue.description }}

Use the ordinary managed repository process. Keep the existing issue branch and PR on retries;
create an issue branch before editing if none exists. Inspect repository instructions and follow
the PR template exactly. Implement a bounded change, update tests and documentation, run `make all`
from `elixir`, and require exact-head remote CI, including the PR-description check. Preserve the
strict lint/specs/Dialyzer/coverage gates and cross-platform packaging checks.

Create or update a PR for human inspection and manual merge, then hand off its URL and validation
results. If blocked, record the blocker and hand it to the operator. Do not merge, change branch
protection, approve deployment, or alter production executables, configuration, state, or credentials.
Do not broaden RequirementRegistry's audit authority beyond its own repository. Candidate code and
tests belong inside this project workspace and the configured sandbox.
