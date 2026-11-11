# Native management

Symphony owns orchestration, durable usage history and the management console in
one Elixir/Phoenix application. There is no Python companion or second web server.
The original OpenAI license and attribution remain; this fork can develop
independently of upstream.

## Run and operate

Use Elixir 1.19 / OTP 28. From `elixir/`, run `mix setup` and `mix build`.
`SYMPHONY_ESCRIPT_PATH=/absolute/staging/symphony mix build` builds away from a
running installation. Install the checked binary into an immutable release
directory and point the service at that directory. Never build over its active
restart executable. The escript includes SQLite's native library and timezone
assets; it extracts them into a private digest-addressed cache before startup.
Burrito releases use their normal application directories.

Set `SYMPHONY_MANAGEMENT_ENABLED=1` in the host service. Set
`SYMPHONY_MANAGEMENT_STATE_DIR` to a durable private directory outside workspaces;
its default is `$XDG_STATE_HOME/symphony` or `~/.local/state/symphony`.
The database is `management.sqlite3`. The directory is mode 0700 and the database
and credential files are mode 0600. Back up SQLite with its backup API or with all
writers stopped. A copied live `.sqlite3` file alone may omit WAL transactions.

The existing loopback HTTP port serves:

- `/`: orchestration and links to the management console.
- `/usage`: UTC date filters, cumulative session counters, model/issue totals,
  runtime, failures, missing observations and configured-rate cost estimates.
- `/settings/notifications`: sender/recipients, Microsoft 365 identity, write-only
  credentials, Slack, channel preferences, schedule, audit controls and rate cards.
- `/reports`: retained reports, provider outcomes, retries and recommendation decisions.
- `/api/v1/usage` and `/api/v1/usage/sessions`: `from`, `until` (exclusive), and
  positive `page` parameters. Invalid parameters return 400; disabled storage 503.

Use an SSH tunnel; management routes require both a loopback peer and loopback
Host header. Phoenix checks local WebSocket origins and protects form submissions
with its normal session/CSRF mechanism. Keep the HTTP listener on loopback.

Settings apply without restarting the service. Blank credential fields preserve
existing values; explicit removal clears a stored value. The browser receives
presence flags only. Versioned credential files and their active SQLite pointer
are committed together; inactive versions remain private for recovery. Shared
GitHub authentication always reads the configured Symphony host environment
variable and never falls back to a separate stored token. Credentials are stripped
from coding worker environments and request logs redact credential parameters.
The host must also deny credential files and management state in the Codex profile.

Test email/Slack buttons send only a requested test, retain accepted/failed
outcomes, and apply a per-channel lease and cooldown. Provider acceptance is not
proof of final receipt. Normal delivery retains IDs, leases, attempts, bounded
backoff and failed/suppressed outcomes; explicit retry does not replay accepted
messages. Disabled or unconfigured channels do not consume retry attempts.

## Host policy

Put immutable execution policy in the host `WORKFLOW.md` front matter. The UI
cannot edit repository identity, paths, commands, permission policy or secret
environment references. Example (replace paths and identities for your host):

```yaml
management:
  repo: example/project
  source_repo: /srv/project-source
  github_auth_mode: symphony
  symphony_github_token_env: SYMPHONY_GITHUB_TOKEN
  slack_webhook_env: VISIBILITY_SLACK_WEBHOOK
  m365_secret_env: VISIBILITY_M365_SECRET
  delivery_enabled: false
  publish_enabled: false
  notifications:
    email: {enabled: false}
    slack: {enabled: true, handoffs: true, blockers: true, weekly: true}
  weekly: {enabled: true, day: Mon, time: '09:00', timezone: UTC}
  rate_card: {version: unconfigured, models: {}}
  workflow:
    required_checks: [validate]
    required_workflows: ['Application checks']
  audit:
    enabled: false
    draft_prs: false
    codex_binary: /absolute/path/to/codex
    model: gpt-6.1-sol
    effort: high
    timeout_seconds: 600
    max_calls_per_week: 2
    proposal_paths: [WORKFLOW.md, 'docs/project-*.md']
    validation_commands: [['bash', 'scripts/project-validate.sh']]
    validation_readable_paths: [/absolute/path/to/pinned/toolchain]
```

Supply Microsoft `email_sender`, `email_recipients`, `m365_tenant`, `m365_client`
and application secret on the host or through the local settings console before
enabling email. Do not commit secrets. Environment references remain supported
for existing installations. Imported `policy.json` is a compatibility fallback;
a nonempty workflow `management` map takes precedence.

Set `codex.preserve_permission_profile: true` only when `codex.command` explicitly
selects the host's named permission profile. The native protocol adapter removes
only `thread/start.sandbox` and `turn/start.sandboxPolicy`; all other fields remain.
Preserve workspace `.git` write access, credential/state deny paths, approvals and
network policy when removing an older stdio bridge.

## Measurements, schedules and audits

Usage observation is asynchronous and bounded. It stores allowlisted metadata,
never prompts, completions, tool arguments or raw protocol/error payloads. Absolute
counters use per-session high-water deltas; delta-only counters are not interpreted
as cumulative totals. Date windows retain earlier baselines. Missing cached-token
information, dropped observations, lost owners and runtime restarts remain visibly
incomplete. Interrupted sessions receive censored ends rather than invented success,
failure, duration or token counts.

Rate cards contain a version and per-million input/output/cached-input rates for
each exact model. Every observation snapshots its applicable card, so changing
rates does not reprice history. Unknown models or incomplete telemetry keep total
cost unknown. Configured subtotals are usage proxies, not subscription invoices.
Weekly reports cover the previous completed UTC week and distinguish observed
coverage, attempts, repairs as proxies, exact-head accepted PRs, CI time and human
waiting. Reports include evidence links and persist publication markers.

The scheduler runs inside the application. Collection, delivery, publication and
analysis have independent supervised tasks. Weekly scheduling uses an IANA zone,
runs the first occurrence of a DST fold, and advances through a spring gap. Audit
scheduling is thirty minutes before the weekly heartbeat, with a separate durable
marker. Manual audit requests still obey leases, time limits and the weekly budget
(maximum three calls). GitHub failures do not block the heartbeat.

Audits get bounded evidence from a disposable clone and prior measurements and
decision notes. Repository text is data, never instructions. Analysis disables
shell/MCP/web tools and cannot merge, deploy, read secrets or broaden permissions.
Recommendations require evidence, an evaluation plan, guardrails, promotion,
rollback and tradeoffs. Optional proposals target the configured project only,
validate fixed host commands in a disposable sandbox, preserve dirty work and
reject symlinks, changed bases or altered candidates. Publication reuses matching
refs/markers and creates **draft PRs only**. Human review and deployment remain
separate decisions. Upstream synchronization is optional maintenance work.

## Migrate from the companion

1. Inspect running work and preserve issue workspaces. Wait for active runs to
   finish, then stop Symphony and every legacy collector/UI/delivery/report/audit
   service and timer. Never run both delivery engines concurrently.
2. Back up private configuration, unit definitions and enablement states, the old
   immutable runtime, SQLite (using its backup API), and telemetry. Keep originals.
3. Build and smoke-test the native artifact with synthetic configuration. Import
   the stopped backup into a **separate** empty native state directory:

   ```sh
   mix management.import --database /backup/visibility.sqlite3 --check
   mix management.import --database /backup/visibility.sqlite3 \
     --config /backup/visibility.json --telemetry /backup/telemetry \
     --state-dir /private/native-state
   ```

   The importer preserves legacy IDs/tables, publication markers, pending and
   accepted delivery states, recommendations and telemetry offsets. It refuses a
   nonempty destination; repeating an already completed import only finishes
   configuration/telemetry finalization. Never point it at actively written state.
4. Move host policy into WORKFLOW, retain credential environment references, and
   replace the Python bridge with direct Codex launch plus the native profile
   adapter. Add the new state/config directories to worker deny paths.
5. Start native management with delivery/publication/audits suppressed. Compare
   imported rows and states to the backup, usage totals, report IDs and published
   URLs. Check local health, settings, history and provider authentication without
   sending a test message. Keep disabled channels disabled.
6. Preserve existing schedule markers. When there is no prior scheduled execution,
   initialize the native markers to the cutover time so installation does not
   send a stale catch-up report. Verify the next future local schedule. Restore
   only the previously enabled feature flags after verification.
7. Disable the old units/timers and verify the old UI port is closed. Keep the
   legacy data and runtime for rollback; remove generic companion source/tests/CI
   from the managed application repository and link to Symphony's documentation.

Rollback: stop native execution first, back up its current database, and reconcile
any deliveries/publications created since cutover before restarting the legacy
engine. Otherwise rollback can duplicate external actions. Restore the backed-up
workflow, launcher, credential environment loading and exact former unit
activation states. Preserve all coding workspaces and both databases. The original
runtime must remain in an immutable path independent of future native builds.

## Validation

`make -C elixir all` is required: dependency setup, executable build, formatting,
specs, strict Credo, tests with **100% coverage**, and Dialyzer. Tests use synthetic
databases, Git repositories, harnesses and fake providers. They cover imports and
partial telemetry, provider failures/retries, shared credentials, scheduling/DST,
owner/writer recovery, exact-head CI, bounded audits, safe draft proposals, native
assets and LiveView controls. Real host sandbox probes require no model call.
