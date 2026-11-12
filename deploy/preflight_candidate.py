#!/usr/bin/env python3
"""Test candidate migrations against copied state in a mandatory isolated namespace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request


class PreflightError(RuntimeError):
    pass


def regular_file(path, parent):
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(parent):
        raise PreflightError(f"Preflight input is not an isolated regular file: {path.name}")
    return path


def prepare(snapshot, destination, revision):
    snapshot = Path(snapshot).resolve(strict=True)
    destination = Path(destination)
    destination.mkdir(mode=0o700)
    entries = json.loads(regular_file(snapshot / "index.json", snapshot).read_text())
    if not isinstance(entries, list) or not entries:
        raise PreflightError("Snapshot has no indexed durable state")
    projects = []
    for entry in entries:
        # Only operator-indexed state roots are candidates. Private configuration
        # copies, credentials, policy files, and executable hooks are never staged.
        if entry.get("state") is not True:
            continue
        copy = Path(entry["copy"])
        if copy.is_symlink():
            raise PreflightError("State copy cannot be a symbolic link")
        copy = copy.resolve(strict=True)
        if not copy.is_relative_to(snapshot) or not copy.is_dir():
            raise PreflightError("State copy escapes the disposable snapshot")
        database = regular_file(copy / "management.sqlite3", snapshot)
        project_id = f"preflight-{len(projects)}"
        state = destination / "states" / project_id
        state.mkdir(mode=0o700, parents=True)
        shutil.copyfile(database, state / "management.sqlite3")
        (state / "management.sqlite3").chmod(0o600)
        checkpoint = copy / "runtime-checkpoint.term"
        if checkpoint.exists() or checkpoint.is_symlink():
            shutil.copyfile(regular_file(checkpoint, snapshot), state / checkpoint.name)
            (state / checkpoint.name).chmod(0o600)
        workflow = destination / f"{project_id}.md"
        workflow.write_text(f"""---
tracker:
  kind: memory
workspace:
  root: /work/workspaces/{project_id}
codex:
  command: "false"
server:
  host: 127.0.0.1
management:
  delivery_enabled: false
  publish_enabled: false
  audit:
    enabled: false
---
Isolated candidate storage compatibility check.
""")
        projects.append({"id": project_id, "workflow_path": f"/work/{workflow.name}",
                         "state_dir": f"/work/states/{project_id}", "enabled": True})
    if not projects:
        raise PreflightError("No operator-indexed management databases were found")
    (destination / "projects.json").write_text(json.dumps({"projects": projects}))
    (destination / "check.json").write_text(json.dumps({"revision": revision, "projects": projects}))
    for name in ["control", "home", "tmp", "workspaces", "install"]:
        (destination / name).mkdir(mode=0o700)
    return projects


def sandbox_command(bwrap, binary, disposable, helper):
    # Build a minimal read-only root rather than exposing the host's read-only
    # credentials and Unix sockets. Only disposable /work is a writable host bind.
    argv = [str(bwrap), "--unshare-all", "--unshare-net", "--die-with-parent", "--new-session",
            "--cap-drop", "ALL", "--clearenv"]
    for path in ["/usr", "/bin", "/sbin", "/lib", "/lib64"]:
        if Path(path).exists():
            argv += ["--ro-bind", path, path]
    argv += ["--dir", "/etc", "--proc", "/proc", "--dev", "/dev",
             "--ro-bind", str(binary), "/candidate/symphony",
             "--ro-bind", str(helper), "/preflight_candidate.py",
             "--bind", str(disposable), "/work", "--symlink", "/work/tmp", "/tmp",
             "--remount-ro", "/", "--chdir", "/work",
             "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/work/home",
             "--setenv", "TMPDIR", "/work/tmp", "--setenv", "LANG", "C.UTF-8",
             "--setenv", "SYMPHONY_EXTERNAL_EFFECTS", "disabled",
             "--setenv", "SYMPHONY_PROJECT_MANIFEST", "/work/projects.json",
             "--setenv", "SYMPHONY_CONTROL_DIR", "/work/control",
             "--setenv", "SYMPHONY_INSTALL_DIR", "/work/install",
             "--setenv", "SYMPHONY_PREFLIGHT_SANDBOX", "1",
             "--", "/usr/bin/python3", "/preflight_candidate.py", "--inside", "/work"]
    return argv


def inside_check(root):
    if root != Path("/work") or os.environ.get("SYMPHONY_PREFLIGHT_SANDBOX") != "1":
        raise PreflightError("The internal checker must run inside the mandatory sandbox")
    checks = json.loads((root / "check.json").read_text())
    paths = sorted(project["state_dir"] for project in checks["projects"])
    state_digest = hashlib.sha256(json.dumps(paths, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    with (root / "candidate.log").open("w+") as log:
        process = subprocess.Popen(["/candidate/symphony",
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--port", str(port),
            checks["projects"][0]["workflow_path"]], stdout=log, stderr=log, cwd=root)
        try:
            deadline = time.monotonic() + 100
            while True:
                try:
                    with urllib.request.urlopen(base + "/api/v1/health", timeout=3) as response:
                        health = json.load(response)
                    valid = (health.get("ready") is True and health.get("revision") == checks["revision"]
                             and health.get("dispatch_paused") is True and health.get("effects_held") is True
                             and health.get("checkpoint_ready") is True and health.get("running_jobs") == 0
                             and health.get("state_paths_sha256") == state_digest
                             and health.get("management_tasks") == 0)
                    if valid:
                        break
                except (OSError, ValueError):
                    pass
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise PreflightError("Candidate storage/migration readiness failed inside the sandbox")
                time.sleep(0.1)
            for project in checks["projects"]:
                database = Path(project["state_dir"]) / "management.sqlite3"
                with sqlite3.connect(database) as connection:
                    if connection.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                        raise PreflightError("Candidate database integrity check failed")
                    if connection.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0] < 1:
                        raise PreflightError("Candidate did not initialize its migrations")
                for suffix in ["", "/usage", "/reports", "/settings/notifications"]:
                    with urllib.request.urlopen(base + f"/projects/{project['id']}" + suffix, timeout=5) as response:
                        if response.status != 200:
                            raise PreflightError("Candidate management navigation failed")
            print("Candidate initialized copied state and passed held readiness in the isolated namespace.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def preflight(environment=None, run=subprocess.run):
    environment = os.environ if environment is None else environment
    if environment.get("SYMPHONY_EXTERNAL_EFFECTS") != "disabled":
        raise PreflightError("External effects must be explicitly disabled")
    bwrap = shutil.which("bwrap", path=environment.get("PATH", "/usr/bin:/bin"))
    if not bwrap:
        raise PreflightError("bubblewrap is required; there is no unsandboxed fallback")
    if not Path("/usr/bin/python3").is_file():
        raise PreflightError("The sandbox requires /usr/bin/python3")
    snapshot = Path(environment["SYMPHONY_PREFLIGHT_SNAPSHOT"]).resolve(strict=True)
    binary = Path(environment["SYMPHONY_PREFLIGHT_BINARY"]).resolve(strict=True)
    revision = json.loads(binary.with_name("manifest.json").read_text())["source_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise PreflightError("Candidate manifest has no immutable source SHA")
    # The operator's snapshot is an input only; candidate receives newly staged
    # database/checkpoint files and synthetic configuration, with no credentials.
    with tempfile.TemporaryDirectory(prefix="isolated-candidate-", dir=snapshot.parent) as temporary:
        disposable = Path(temporary) / "runtime"
        prepare(snapshot, disposable, revision)
        argv = sandbox_command(bwrap, binary, disposable, Path(__file__).resolve())
        run(argv, check=True, timeout=115, env={"PATH": "/usr/bin:/bin"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.inside is not None:
            inside_check(args.inside)
        else:
            preflight()
    except (PreflightError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Candidate preflight failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
