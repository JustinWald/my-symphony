#!/usr/bin/env python3
"""Operator-only, drain-before-restart promotion of a verified CI artifact."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request


class DeploymentError(RuntimeError):
    pass


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync_directory(path.parent)


def sync_directory(path):
    descriptor = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def command(argv, **options):
    return subprocess.run(argv, check=True, text=True, capture_output=True, timeout=120, **options).stdout


class Deployer:
    def __init__(self, config, run=command, clock=time.monotonic, sleep=time.sleep):
        self.config, self.run, self.clock, self.sleep = config, run, clock, sleep
        self.control = Path(config["control_dir"]).resolve()
        self.releases = Path(config["release_root"]).resolve()
        self.pause = self.control / "pause.json"
        self.journal = self.control / "deployment.json"
        self.current = self.releases / "current"
        self.drain_seconds = 1200
        self.observation_seconds = 120
        protected = [self.control, self.releases]
        sources = [Path(value).resolve() for value in config["state_dirs"] + config["configuration_paths"]]
        for source in sources:
            if any(source == path or source in path.parents or path in source.parents for path in protected):
                raise DeploymentError("State/configuration paths must not overlap deployment control or releases")
        for index, source in enumerate(sources):
            if any(source == other or source in other.parents or other in source.parents for other in sources[:index]):
                raise DeploymentError("Backup sources must not overlap")

    def state_digest(self):
        paths = sorted(str(Path(value).resolve()) for value in self.config["state_dirs"])
        encoded = json.dumps(paths, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def state_matches(self, health):
        return health.get("state_paths_sha256") == self.state_digest()

    @contextlib.contextmanager
    def locked(self):
        self.control.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (self.control / "deployment.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise DeploymentError("Another deployment owns the lock") from error
            yield

    def github(self, endpoint):
        return json.loads(self.run(["gh", "api", endpoint]))

    def verify_and_fetch(self, sha):
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise DeploymentError("--sha must be a full lowercase source commit SHA")
        repository = self.config["repository"]
        prefix = f"repos/{repository}"
        comparison = self.github(f"{prefix}/compare/{sha}...main")
        if comparison["status"] not in ("ahead", "identical"):
            raise DeploymentError("Candidate source is not on main")
        checks = self.github(f"{prefix}/commits/{sha}/check-runs?per_page=100")["check_runs"]
        for name in self.config["required_checks"]:
            matching = [check for check in checks if check["name"] == name and check["head_sha"] == sha]
            if not matching or max(matching, key=lambda check: check["id"])["conclusion"] != "success":
                raise DeploymentError(f"Required exact-head check did not pass: {name}")
        workflow = self.config.get("candidate_workflow", "candidate.yml")
        runs = self.github(f"{prefix}/actions/workflows/{workflow}/runs?head_sha={sha}&event=push&status=success&per_page=100")
        matching = [run for run in runs["workflow_runs"] if run["head_sha"] == sha and run["head_branch"] == "main"]
        if not matching:
            raise DeploymentError("No passing candidate build for the merged SHA")
        run_id = max(matching, key=lambda run: run["id"])["id"]
        destination = self.releases / sha
        if destination.exists():
            raise DeploymentError("Release directory already exists; inspect or remove it before retrying")
        self.releases.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=self.releases, prefix=".candidate-") as temporary:
            self.run(["gh", "run", "download", str(run_id), "--repo", repository,
                      "--name", "candidate-linux_x86_64", "--dir", temporary])
            manifest = json.loads((Path(temporary) / "manifest.json").read_text())
            binary = Path(temporary) / "symphony"
            if manifest.get("source_sha") != sha or manifest.get("target") != "linux_x86_64":
                raise DeploymentError("Candidate source or platform mismatch")
            if manifest.get("sha256") != hashlib.sha256(binary.read_bytes()).hexdigest():
                raise DeploymentError("Candidate checksum mismatch")
            compatibility = manifest.get("database_compatibility", {})
            if self.config["state_format"] not in compatibility.get("reads", []):
                raise DeploymentError("Candidate cannot read the deployed state format")
            if compatibility.get("writes") != self.config["state_format"]:
                raise DeploymentError("State format changes require a separately reviewed migration procedure")
            if manifest.get("runtime") != self.config["runtime"]:
                raise DeploymentError("Candidate runtime requirements differ from the approved host requirements")
            binary.chmod(0o500)
            for path in [binary, Path(temporary) / "manifest.json"]:
                with path.open("rb") as stream:
                    os.fsync(stream.fileno())
            os.rename(temporary, destination)
            sync_directory(self.releases)
        return destination

    def health(self):
        with urllib.request.urlopen(self.config["health_url"], timeout=5) as response:
            return json.load(response)

    def wait_for(self, predicate, seconds, description):
        deadline = self.clock() + seconds
        while True:
            try:
                if predicate(self.health()):
                    return
            except (OSError, ValueError):
                pass
            if self.clock() >= deadline:
                raise DeploymentError(f"Timed out waiting for {description}")
            self.sleep(min(1, max(0, deadline - self.clock())))

    def hold(self, token, effects):
        atomic_json(self.pause, {"dispatch_paused": True, "effects_held": effects, "token": token})

    def record(self, state, phase):
        state["phase"] = phase
        atomic_json(self.journal, state)

    def snapshot(self, destination):
        destination.mkdir(mode=0o700)
        entries = []
        for index, value in enumerate(self.config["state_dirs"] + self.config["configuration_paths"]):
            source = Path(value).resolve(strict=True)
            target = destination / str(index)
            if source.is_dir():
                shutil.copytree(source, target, ignore=shutil.ignore_patterns("*.sqlite3", "*.sqlite3-wal", "*.sqlite3-shm"))
                for database in source.rglob("*.sqlite3"):
                    copy = target / database.relative_to(source)
                    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as live, sqlite3.connect(copy) as saved:
                        live.backup(saved)
            else:
                shutil.copy2(source, target)
            entries.append({"source": str(source), "copy": str(target), "directory": source.is_dir(),
                            "state": index < len(self.config["state_dirs"])})
        atomic_json(destination / "index.json", entries)
        for path in destination.rglob("*"):
            if path.is_file():
                with path.open("rb") as stream:
                    os.fsync(stream.fileno())
        sync_directory(destination)
        return entries

    def preflight(self, binary, backup):
        argv = self.config.get("preflight_argv")
        if not argv:
            raise DeploymentError("Configure an isolated preflight hook before promotion")
        # The hook gets disposable copies, never the backup needed for rollback.
        with tempfile.TemporaryDirectory(prefix="preflight-", dir=self.control) as temporary:
            isolated = Path(temporary) / "snapshot"
            shutil.copytree(backup, isolated)
            entries = json.loads((isolated / "index.json").read_text())
            for index, entry in enumerate(entries):
                entry["copy"] = str(isolated / str(index))
            atomic_json(isolated / "index.json", entries)
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": temporary,
                   "SYMPHONY_EXTERNAL_EFFECTS": "disabled", "SYMPHONY_CONTROL_DIR": temporary,
                   "SYMPHONY_PREFLIGHT_SNAPSHOT": str(isolated), "SYMPHONY_PREFLIGHT_BINARY": str(binary)}
            self.run(argv, env=env)

    def switch(self, target):
        temporary = self.releases / ".current-next"
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(target)
        os.replace(temporary, self.current)
        sync_directory(self.releases)

    def ready(self, health, revision):
        return (health.get("ready") is True and health.get("revision") == revision
                and self.state_matches(health)
                and health.get("dispatch_paused") is True and health.get("effects_held") is True)

    def observe(self, revision):
        self.wait_for(lambda health: self.ready(health, revision), 120, "held runtime readiness")
        deadline = self.clock() + self.observation_seconds
        while self.clock() < deadline:
            if not self.ready(self.health(), revision):
                raise DeploymentError("Runtime lost readiness during observation")
            self.sleep(min(1, deadline - self.clock()))

    def restore(self, state):
        self.hold(state["token"], True)
        if state.get("snapshot_complete"):
            self.run(self.config["stop_argv"])
            for entry in json.loads((Path(state["backup"]) / "index.json").read_text()):
                source, saved = Path(entry["source"]), Path(entry["copy"])
                if entry["directory"]:
                    shutil.rmtree(source)
                    shutil.copytree(saved, source)
                else:
                    shutil.copy2(saved, source)
            self.switch(state["previous_release"])
            self.run(self.config["start_argv"])
            self.observe(state["previous_revision"])
        # Rollback resumption has the same irreversible boundary as promotion:
        # a later recovery must not stop workers that may already have resumed.
        self.record(state, "rollback_resuming")
        self.pause.unlink(missing_ok=True)
        sync_directory(self.control)
        self.record(state, "rolled_back")

    def promote(self, sha):
        with self.locked():
            if self.pause.exists():
                raise DeploymentError("A durable hold already exists; inspect it or run recover")
            if self.journal.exists():
                phase = json.loads(self.journal.read_text())["phase"]
                if phase not in ("completed", "rolled_back"):
                    raise DeploymentError("Interrupted deployment requires recover")
            candidate = self.verify_and_fetch(sha)
            previous = self.current.resolve(strict=True)
            old_health = self.health()
            if not old_health.get("ready") or not old_health.get("revision"):
                raise DeploymentError("Existing runtime is not ready or has no revision")
            if not self.state_matches(old_health):
                raise DeploymentError("Configured backups do not cover the runtime's exact durable state paths")
            token = os.urandom(16).hex()
            state = {"token": token, "source_sha": sha, "previous_release": str(previous),
                     "previous_revision": old_health["revision"], "backup": str(self.control / f"backup-{token}")}
            self.record(state, "draining")
            self.hold(token, False)
            try:
                self.wait_for(lambda health: health.get("dispatch_paused") is True
                              and health.get("running_jobs") == 0, self.drain_seconds, "complete job drain")
                self.hold(token, True)
                self.record(state, "checkpointing")
                self.wait_for(lambda health: health.get("effects_held") is True
                              and health.get("checkpoint_ready") is True
                              and self.state_matches(health)
                              and health.get("running_jobs") == 0
                              and health.get("management_tasks") == 0, 120, "management checkpoint")
                self.snapshot(Path(state["backup"]))
                state["snapshot_complete"] = True
                self.record(state, "preflight")
                self.preflight(candidate / "symphony", Path(state["backup"]))
                self.record(state, "activating")
                self.run(self.config["stop_argv"])
                self.switch(candidate)
                self.run(self.config["start_argv"])
                self.observe(sha)
                # Mark the irreversible boundary BEFORE releasing effects. An interruption
                # here requires reconciliation; older state must never be restored blindly.
                self.record(state, "effects_resuming")
                self.pause.unlink()
                sync_directory(self.control)
                self.record(state, "completed")
            except Exception:
                if state["phase"] in ("effects_resuming", "completed"):
                    self.hold(token, True)
                    raise DeploymentError("Effects may have resumed; processing is held for reconciliation") from None
                self.restore(state)
                raise

    def recover(self):
        with self.locked():
            state = json.loads(self.journal.read_text())
            if state["phase"] in ("completed", "rolled_back") and not self.pause.exists():
                return
            if state["phase"] in ("effects_resuming", "rollback_resuming", "completed", "rolled_back"):
                self.hold(state["token"], True)
                raise DeploymentError("Effects may have resumed; reconcile durable state before any rollback")
            self.restore(state)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["promote", "recover"])
    parser.add_argument("--sha")
    parser.add_argument("--approve", action="store_true")
    parser.add_argument("--config", default="/etc/symphony/deploy.json")
    args = parser.parse_args(argv)
    if not args.approve:
        parser.error("explicit operator approval requires --approve")
    if args.action == "promote" and not args.sha:
        parser.error("promote requires --sha")
    try:
        config = json.loads(Path(args.config).read_text())
        deployer = Deployer(config)
        if args.action == "promote":
            deployer.promote(args.sha)
        else:
            deployer.recover()
    except (DeploymentError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"Deployment failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
