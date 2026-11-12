#!/usr/bin/env python3
"""Boot the packaged executable against synthetic, disposable local state twice."""
import json
import os
from pathlib import Path
import socket
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request


def request(base, path):
    with urllib.request.urlopen(base + path, timeout=5) as response:
        assert response.status == 200, path
        return response.read()


def boot(binary, revision, root, workflows, projects, environment, port, iteration):
    base = f"http://127.0.0.1:{port}"
    with (root / f"boot-{iteration}.log").open("w+") as log:
        process = subprocess.Popen([binary,
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
            "--port", str(port), str(workflows[0])], cwd=root, env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 120
            while True:
                try:
                    health = json.loads(request(base, "/api/v1/health"))
                    if health["ready"]:
                        break
                except (OSError, ValueError):
                    pass
                if process.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError("Packaged runtime did not become ready:\n" + log.read())
                time.sleep(0.2)
            assert health["revision"] == revision, health
            assert b"Operations Dashboard" in request(base, "/")
            for path in ["/usage", "/reports", "/settings/notifications", "/api/v1/state"]:
                request(base, path)
            if len(projects) > 1:
                listing = json.loads(request(base, "/api/v1/projects"))
                assert "alpha" in str(listing) and "beta" in str(listing), listing
                for project in projects:
                    for suffix in ["", "/usage", "/reports", "/settings/notifications"]:
                        request(base, f"/projects/{project}" + suffix)
                    request(base, f"/api/v1/projects/{project}/state")
            if iteration == 0:
                while True:
                    complete = True
                    for project in projects:
                        database = root / project / "state" / "management.sqlite3"
                        try:
                            with sqlite3.connect(database) as connection:
                                rows = connection.execute("SELECT input,output FROM usage_observations").fetchall()
                                finished = connection.execute("SELECT count(*) FROM events WHERE kind='finish'").fetchone()[0]
                                complete = complete and (10, 2) in rows and finished > 0
                        except sqlite3.OperationalError:
                            complete = False
                    if complete:
                        break
                    if time.monotonic() > deadline:
                        log.seek(0)
                        raise AssertionError("Fake workers failed to persist usage/completion:\n" + log.read())
                    time.sleep(0.2)
            for project in projects:
                database = root / project / "state" / "management.sqlite3"
                with sqlite3.connect(database) as connection:
                    assert connection.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0] > 0
                    assert connection.execute("SELECT MAX(input),MAX(output) FROM usage_observations").fetchone() == (10, 2)
                    assert connection.execute("SELECT COUNT(*) FROM events WHERE kind='start'").fetchone()[0] == 1
                prefix = f"/api/v1/projects/{project}" if len(projects) > 1 else "/api/v1"
                usage = json.loads(request(base, prefix + "/usage"))
                assert usage["data"]["input"] == 10, usage
        finally:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def smoke(binary, revision):
    binary = str(Path(binary).resolve())
    worker = Path(__file__).with_name("fake_worker.py").resolve()
    for projects in [["alpha"], ["alpha", "beta"]]:
        with tempfile.TemporaryDirectory(prefix="symphony-artifact-") as temporary:
            root = Path(temporary)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": temporary,
                           "SYMPHONY_INSTALL_DIR": str(root / "install"),
                           "SYMPHONY_MANAGEMENT_ENABLED": "1",
                           "SYMPHONY_MANAGEMENT_STATE_DIR": str(root / "alpha" / "state"),
                           "SYMPHONY_CONTROL_DIR": str(root / "control")}
            workflows = []
            entries = []
            for project in projects:
                directory = root / project
                directory.mkdir()
                issues = directory / "issues.json"
                issues.write_text(json.dumps([{"id": "1", "identifier": "ISSUE-1",
                    "title": "Synthetic coding job", "description": "Test only", "state": "Todo",
                    "priority": 1, "dispatchable": True, "labels": ["symphony-ready"]}]))
                workflow = directory / "WORKFLOW.md"
                command = " ".join(shlex.quote(value) for value in ["python3", str(worker), str(issues), str(root / "workers.jsonl"), project])
                workflow.write_text(f"""---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
  provider:
    issues_file: {json.dumps(str(issues))}
polling:
  interval_ms: 100
workspace:
  root: ./workspaces
agent:
  max_turns: 1
codex:
  command: {json.dumps(command)}
server:
  host: 127.0.0.1
management:
  delivery_enabled: false
  publish_enabled: false
  audit:
    enabled: false
---
Synthetic artifact compatibility check.
""")
                workflows.append(workflow)
                entries.append({"id": project, "workflow_path": str(workflow), "state_dir": str(directory / "state"), "enabled": True})
            if len(projects) > 1:
                manifest = root / "projects.json"
                manifest.write_text(json.dumps({"projects": entries}))
                environment["SYMPHONY_PROJECT_MANIFEST"] = str(manifest)
            for iteration in range(2):
                boot(binary, revision, root, workflows, projects, environment, port, iteration)
            trace = [json.loads(line) for line in (root / "workers.jsonl").read_text().splitlines()]
            assert sorted(row["project"] for row in trace) == sorted(projects), trace
            for row in trace:
                assert Path(row["cwd"]).is_relative_to(root / row["project"] / "workspaces"), row
                assert row["host_runtime_environment"] == [], row
            if len(projects) > 1:
                snapshot = root / "preflight-input"
                snapshot.mkdir()
                entries = []
                for index, project in enumerate(projects):
                    source = root / project / "state"
                    copy = snapshot / str(index)
                    shutil.copytree(source, copy)
                    # Sentinel proves that live credential files are not required
                    # to initialize copied durable state under synthetic bindings.
                    (copy / "credentials.json").write_text('{"github_token":"fixture-must-not-be-staged"}')
                    entries.append({"source": str(source), "copy": str(copy), "directory": True, "state": True})
                (snapshot / "index.json").write_text(json.dumps(entries))
                subprocess.run([sys.executable, str(Path(__file__).with_name("preflight_candidate.py"))],
                    check=True, timeout=120, env={"PATH": environment["PATH"], "SYMPHONY_EXTERNAL_EFFECTS": "disabled",
                        "SYMPHONY_PREFLIGHT_BINARY": binary, "SYMPHONY_PREFLIGHT_SNAPSHOT": str(snapshot)})


if __name__ == "__main__":
    smoke(*sys.argv[1:])
