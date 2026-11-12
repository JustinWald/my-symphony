# Operator-controlled promotion

`symphony-deploy` runs outside coding agents and the application. It requires Python 3.10+, Linux `flock`, an authenticated `gh` CLI, and an operator-owned private configuration. The provided preflight hook additionally requires bubblewrap, permitted user/network namespaces, and `/usr/bin/python3`; missing or unavailable sandbox support fails closed. Keep its configuration, release directory, control directory, and state backups outside coding workspaces and their sandbox write permissions. The application and operator must agree on `SYMPHONY_CONTROL_DIR`. Do not expose promotion as an agent tool or HTTP endpoint.

`examples/projects.json` and `examples/SYMPHONY-WORKFLOW.md` show private manifest and self-development workflow structure. Replace every placeholder before use. Keep RequirementRegistry's existing workflow/state/workspaces at their existing paths, and list it first to preserve legacy route defaults. Set `SYMPHONY_PROJECT_MANIFEST` to the private manifest while retaining the legacy workflow invocation. Each project uses its own tracker binding, workspace root and state directory.

The workspace bootstrap hook takes a repository and full reviewed, CI-passing **development source** SHA. It fetches/checks out that exact revision into an empty workspace; it never follows `main`. On retry it verifies the stored source/repository binding and preserves the issue branch and uncommitted work. A mismatch fails instead of resetting work. The operator selects and updates this source SHA after review independently of the **deployed runtime** SHA in `release_root/current`. Neither selecting a newer development source nor creating a PR changes the production executable. The hook does not grant production deployment approval or replace the normal review/CI process.

The `deployment-candidate` workflow runs the source gates, packages Linux x86-64 from the exact commit, and starts that executable with synthetic single-workflow and two-project configurations. It exercises dashboard/management routes, SQLite initialization, fake Codex execution with identical issue numbers, usage recording, isolated workspace paths, then restart recovery without duplicate execution. The uploaded artifact contains `symphony` and `manifest.json`, including source SHA, checksum, tested runtime, and state format. Existing cross-platform release checks remain in place. Artifact retention is 30 days; expired candidates require a new reviewed build, not a production-host rebuild.

The operator downloads only a successful `candidate.yml` run from `main` at the requested SHA. It checks that the SHA remains on `main`, that the latest required check runs passed at that exact SHA, and that source, platform, checksum, runtime requirements, and state compatibility match. The current implementation permits state format 1; a format change needs a separately reviewed migration procedure. Binary rollback after effects resume is deliberately disabled (`binary_rollback_tested: false`).

Install the wrapper and Python file together. For example, a private `/etc/symphony/deploy.json` contains:

```json
{
  "repository": "JustinWald/my-symphony",
  "release_root": "/var/lib/symphony/releases",
  "control_dir": "/var/lib/symphony/deploy-control",
  "state_dirs": [
    "/var/lib/symphony/requirementregistry",
    "/var/lib/symphony/self"
  ],
  "configuration_paths": ["/etc/symphony/projects", "/etc/symphony/service.env"],
  "health_url": "http://127.0.0.1:4687/api/v1/health",
  "required_checks": ["make-all", "candidate-linux_x86_64"],
  "candidate_workflow": "candidate.yml",
  "state_format": 1,
  "runtime": {"kind": "burrito", "tested_on": "ubuntu-24.04", "bundled_erlang": true},
  "preflight_argv": ["/usr/bin/python3", "/PRIVATE/operator-tools/preflight_candidate.py"],
  "stop_argv": ["systemctl", "--user", "stop", "symphony.service"],
  "start_argv": ["systemctl", "--user", "start", "symphony.service"]
}
```

These paths are examples, not production defaults. List every durable project state directory and private runtime configuration path. The operator compares the health endpoint's digest of enabled project state paths with the configured backup paths before draining, at checkpoint, and throughout readiness/observation. Missing, extra, or changed state paths fail closed. Sources must exist, must not overlap each other, and must not overlap release/control directories. The service must execute `release_root/current/symphony`; bootstrap `current` to its existing pinned, known-good release before first promotion. That release must already implement the pause/health/checkpoint protocol. Keep deployment-control and its backups mode `0700` because snapshots can contain credentials. The operator copies configuration and uses SQLite's backup API for each `*.sqlite3` database after checkpoint readiness. It never alters development source selection.

The preflight hook is **mandatory** and must be installed and reviewed by the operator before enabling promotion. It receives a minimal environment, including:

- `SYMPHONY_PREFLIGHT_BINARY`: the exact candidate executable.
- `SYMPHONY_PREFLIGHT_SNAPSHOT`: disposable state/configuration copies; `index.json` maps original source paths to each isolated `copy` path.
- `SYMPHONY_EXTERNAL_EFFECTS=disabled` and an isolated `SYMPHONY_CONTROL_DIR` and `HOME`.

Install the provided `preflight_candidate.py` in the private operator-tools directory and configure the hook as shown. It reads the snapshot's operator-generated index, selects only indexed durable state directories, and stages only `management.sqlite3` and optional `runtime-checkpoint.term` in fresh copies. Credential files, policy files, production workflows, hooks, and live tracker bindings are omitted. Synthetic memory-tracker workflows reference only isolated workspace/state paths, disable coding and management effects, and preserve the copied database/checkpoint content for actual startup/migration tests.

The hook invokes bubblewrap with new network/process/user namespaces, no capabilities, a cleared environment, a minimal read-only root containing system runtime directories plus the candidate/helper, and one writable disposable `/work` bind. Production state/configuration, home directories, credentials and host service sockets are not mounted. Both candidate startup and the HTTP checker run in that namespace. The checker requires the candidate's expected revision, exact isolated state-path digest, migrations/storage readiness, both holds, zero jobs/tasks, a complete checkpoint, SQLite integrity, and project management navigation. Candidate failure, timeout, unavailable bubblewrap, or denied namespace setup aborts promotion; there is no unsandboxed fallback. The candidate sees private historical database content inside the isolated namespace, but no credential files or production write paths. Never point the hook at the rollback backup or production paths.

After review, human merge, required CI, and explicit production approval:

```sh
symphony-deploy promote --sha FULL_MERGED_COMMIT_SHA --approve
```

Promotion serializes operators, durably pauses new dispatch, and waits at most 20 minutes for workers to finish. A timeout resumes the existing version without stopping workers. It then holds external effects, waits for management tasks and checkpoints, snapshots state/configuration, runs the isolated preflight hook, stops the drained service, atomically changes `current`, and starts the candidate. Dispatch/effects stay held through readiness and a two-minute observation. Only then are they resumed.

Activation failure restores executable, configuration and durable state while effects remain held, verifies the old version, and resumes. Interrupted pre-resume deployments use the same recovery path:

```sh
symphony-deploy recover --approve
```

The journal records the effect-resumption boundary **before** removing the hold. An interruption at or after that boundary pauses processing and requires operator reconciliation; recovery will not restore old state, which could repeat jobs or notifications. A failed rollback also leaves the hold in place. Do not delete holds or edit journals until the recorded phase and actual service state have been reconciled. Snapshots and journal are retained for inspection; remove obsolete snapshots only after a successful rollout review.

To configure main protection, review `main-protection.json` and apply it with the repository administrator identity:

```sh
python3 deploy/configure_main_protection.py
# After reviewing the dry run:
python3 deploy/configure_main_protection.py --approve
```

This requires a PR, the PR description check, exact-head source and candidate CI with a current base, resolved conversations, and administrator enforcement; force pushes, deletion, and PR bypass actors are disabled. Human inspection and manual merge use the existing GitHub identity. The review count is zero because GitHub does not allow that identity to approve its own PR; human inspection remains a workflow requirement. Applying it is an explicit repository administration action. This change does not apply it automatically, merge PRs, enable self-development, or deploy production. Complete the two-project active-job drill, private preflight integration, human handoff, merge, and approved deployment loop before enabling ongoing self-development.

Run operator regression tests locally with `python3 -m unittest discover -s deploy/tests -v`. They exercise drain timeout without stopping jobs, checksum/CI/source failures, preflight input preparation and sandbox boundaries, migration/restart failures, interrupted activation, restore, serialization, and the irreversible effects boundary. Artifact startup/restart, fake Codex execution, and real namespaced preflight against synthetic state run in candidate CI; production notification deduplication still requires the application integration tests and production rollout drill.

On Ubuntu, [AppArmor mediates unprivileged user namespaces](https://documentation.ubuntu.com/security/security-features/privilege-restriction/apparmor/).
The clean CI runner loads the distribution's `bwrap-userns-restrict` profile before
running the isolated preflight. Production preflight must pass under its host's
approved namespace policy. The [upstream AppArmor profile](https://gitlab.com/apparmor/apparmor/-/blob/master/profiles/apparmor/profiles/extras/bwrap-userns-restrict)
allows namespace setup by bubblewrap while restricting its children. No production
host policy is modified by this PR.
