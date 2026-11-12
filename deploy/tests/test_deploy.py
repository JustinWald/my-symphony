import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "symphony_deploy.py"
SPEC = importlib.util.spec_from_file_location("symphony_deploy", MODULE)
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)

OLD = "a" * 40
NEW = "b" * 40


class Fixture(deploy.Deployer):
    def __init__(self, root):
        self.now = 0
        self.commands = []
        self.active = OLD
        self.jobs = 2
        self.fail_candidate = False
        self.preflight_failure = False
        self.database = root / "state" / "management.sqlite3"
        self.database.parent.mkdir()
        with sqlite3.connect(self.database) as connection:
            connection.execute("CREATE TABLE jobs(id INTEGER PRIMARY KEY, status TEXT)")
            connection.execute("INSERT INTO jobs VALUES(1,'complete')")
        config_file = root / "private.json"
        config_file.write_text("private configuration")
        config = {
            "control_dir": str(root / "control"), "release_root": str(root / "releases"),
            "repository": "owner/example", "state_dirs": [str(self.database.parent)],
            "configuration_paths": [str(config_file)], "required_checks": ["make-all"],
            "state_format": 1, "runtime": {"kind": "burrito"},
            "health_url": "http://localhost/api/v1/health",
            "preflight_argv": ["preflight"], "stop_argv": ["stop"], "start_argv": ["start"],
        }
        super().__init__(config, run=self.execute, clock=lambda: self.now, sleep=self.advance)
        previous = self.releases / OLD
        previous.mkdir(parents=True)
        self.current.symlink_to(previous)
        self.observation_seconds = 2
        self.drain_seconds = 3
        self.health_log = []

    def advance(self, seconds):
        self.now += seconds
        if self.jobs:
            self.jobs -= 1

    def health(self):
        hold = json.loads(self.pause.read_text()) if self.pause.exists() else {}
        result = {"ready": True, "revision": self.active, "running_jobs": self.jobs,
                  "state_paths_sha256": self.state_digest(),
                  "management_tasks": 0, "checkpoint_ready": not self.jobs and hold.get("effects_held", False),
                  "dispatch_paused": hold.get("dispatch_paused", False),
                  "effects_held": hold.get("effects_held", False)}
        self.health_log.append(result)
        return result

    def verify_and_fetch(self, sha):
        path = self.releases / sha
        path.mkdir()
        (path / "symphony").write_text("candidate")
        return path

    def execute(self, argv, **kwargs):
        self.commands.append(argv)
        if argv == ["start"]:
            revision = self.current.resolve().name
            if revision == NEW and self.fail_candidate:
                with sqlite3.connect(self.database) as connection:
                    connection.execute("UPDATE jobs SET status='bad migration'")
                raise subprocess.CalledProcessError(1, argv)
            self.active = revision
        if argv == ["preflight"]:
            environment = kwargs["env"]
            assert environment["SYMPHONY_EXTERNAL_EFFECTS"] == "disabled"
            assert "GH_TOKEN" not in environment
            isolated = Path(environment["SYMPHONY_PREFLIGHT_SNAPSHOT"])
            entries = json.loads((isolated / "index.json").read_text())
            assert all(Path(entry["copy"]).is_relative_to(isolated) for entry in entries)
            with sqlite3.connect(Path(entries[0]["copy"]) / "management.sqlite3") as connection:
                connection.execute("UPDATE jobs SET status='disposable'")
            if self.preflight_failure:
                raise subprocess.CalledProcessError(1, argv)
        return ""


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = Fixture(self.root)

    def test_promotion_drains_before_stopping_and_observes_held_candidate(self):
        self.fixture.promote(NEW)
        self.assertEqual(self.fixture.current.resolve().name, NEW)
        self.assertEqual(self.fixture.commands, [["preflight"], ["stop"], ["start"]])
        self.assertFalse(self.fixture.pause.exists())
        self.assertEqual(json.loads(self.fixture.journal.read_text())["phase"], "completed")
        with sqlite3.connect(self.fixture.database) as connection:
            self.assertEqual(connection.execute("SELECT status FROM jobs").fetchone()[0], "complete")
        self.assertTrue(any(row["running_jobs"] == 2 and row["dispatch_paused"] for row in self.fixture.health_log))
        self.assertTrue(any(row["revision"] == NEW and row["effects_held"] for row in self.fixture.health_log))

    def test_drain_timeout_never_stops_active_jobs(self):
        self.fixture.jobs = 100
        with self.assertRaisesRegex(deploy.DeploymentError, "complete job drain"):
            self.fixture.promote(NEW)
        self.assertEqual(self.fixture.commands, [])
        self.assertEqual(self.fixture.current.resolve().name, OLD)
        self.assertFalse(self.fixture.pause.exists())

    def test_failed_migration_or_restart_restores_state_and_binary_while_held(self):
        self.fixture.fail_candidate = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.fixture.promote(NEW)
        self.assertEqual(self.fixture.current.resolve().name, OLD)
        self.assertFalse(self.fixture.pause.exists())
        with sqlite3.connect(self.fixture.database) as connection:
            self.assertEqual(connection.execute("SELECT status FROM jobs").fetchone()[0], "complete")
        self.assertEqual(json.loads(self.fixture.journal.read_text())["phase"], "rolled_back")

    def test_failed_preflight_keeps_previous_version_and_disposable_changes_isolated(self):
        self.fixture.preflight_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.fixture.promote(NEW)
        self.assertEqual(self.fixture.active, OLD)
        with sqlite3.connect(self.fixture.database) as connection:
            self.assertEqual(connection.execute("SELECT status FROM jobs").fetchone()[0], "complete")

    def test_interrupted_activation_recovers_from_durable_journal(self):
        self.fixture.jobs = 0
        self.fixture.control.mkdir()
        state = {"token": "token", "previous_release": str(self.fixture.current.resolve()),
                 "previous_revision": OLD, "backup": str(self.fixture.control / "backup")}
        self.fixture.snapshot(Path(state["backup"]))
        state["snapshot_complete"] = True
        self.fixture.record(state, "activating")
        self.fixture.hold("token", True)
        with sqlite3.connect(self.fixture.database) as connection:
            connection.execute("UPDATE jobs SET status='partial upgrade'")
        self.fixture.recover()
        with sqlite3.connect(self.fixture.database) as connection:
            self.assertEqual(connection.execute("SELECT status FROM jobs").fetchone()[0], "complete")

    def test_after_effects_may_resume_recovery_requires_reconciliation(self):
        self.fixture.control.mkdir()
        self.fixture.record({"token": "token"}, "effects_resuming")
        with self.assertRaisesRegex(deploy.DeploymentError, "reconcile"):
            self.fixture.recover()
        self.assertTrue(json.loads(self.fixture.pause.read_text())["effects_held"])
        self.assertEqual(self.fixture.commands, [])

    def test_recover_after_completed_rollback_cannot_stop_resumed_workers(self):
        self.fixture.jobs = 100
        with self.assertRaises(deploy.DeploymentError):
            self.fixture.promote(NEW)
        self.fixture.recover()
        self.assertEqual(self.fixture.commands, [])
        self.assertFalse(self.fixture.pause.exists())

    def test_interrupted_rollback_resumption_does_not_restore_older_state(self):
        self.fixture.control.mkdir()
        self.fixture.record({"token": "token"}, "rollback_resuming")
        with self.assertRaisesRegex(deploy.DeploymentError, "reconcile"):
            self.fixture.recover()
        self.assertEqual(self.fixture.commands, [])

    def test_deployment_lock_serializes_operators(self):
        with self.fixture.locked():
            with self.assertRaisesRegex(deploy.DeploymentError, "owns the lock"):
                with self.fixture.locked():
                    self.fail("Acquired duplicate lock")

    def test_existing_operator_hold_is_preserved(self):
        self.fixture.hold("someone-else", True)
        with self.assertRaisesRegex(deploy.DeploymentError, "hold already exists"):
            self.fixture.promote(NEW)
        self.assertEqual(json.loads(self.fixture.pause.read_text())["token"], "someone-else")

    def test_candidate_losing_readiness_rolls_back_before_effects_resume(self):
        original = self.fixture.health
        def health():
            result = original()
            if self.fixture.active == NEW:
                result["ready"] = False
            return result
        self.fixture.health = health
        with self.assertRaisesRegex(deploy.DeploymentError, "readiness"):
            self.fixture.promote(NEW)
        self.assertEqual(self.fixture.active, OLD)
        self.assertFalse(self.fixture.pause.exists())

    def test_backup_paths_cannot_include_control_state(self):
        config = dict(self.fixture.config, state_dirs=[str(self.root)])
        with self.assertRaisesRegex(deploy.DeploymentError, "overlap"):
            deploy.Deployer(config)

    def test_missing_project_state_cannot_be_promoted(self):
        original = self.fixture.health
        def health():
            result = original()
            result["state_paths_sha256"] = "different project state set"
            return result
        self.fixture.health = health
        with self.assertRaisesRegex(deploy.DeploymentError, "exact durable state paths"):
            self.fixture.promote(NEW)
        self.assertFalse(self.fixture.pause.exists())
        self.assertEqual(self.fixture.commands, [])

    def test_candidate_cannot_change_project_durable_state_mapping(self):
        original = self.fixture.health
        def health():
            result = original()
            if self.fixture.active == NEW:
                result["state_paths_sha256"] = "different project state set"
            return result
        self.fixture.health = health
        with self.assertRaisesRegex(deploy.DeploymentError, "readiness"):
            self.fixture.promote(NEW)
        self.assertEqual(self.fixture.active, OLD)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Fixture(Path(self.temporary.name))
        self.responses = {}
        self.good_manifest = {"source_sha": NEW, "target": "linux_x86_64",
                              "sha256": hashlib.sha256(b"binary").hexdigest(),
                              "database_compatibility": {"reads": [1], "writes": 1},
                              "runtime": {"kind": "burrito"}}
        prefix = "repos/owner/example"
        self.responses[f"{prefix}/compare/{NEW}...main"] = {"status": "ahead"}
        self.responses[f"{prefix}/commits/{NEW}/check-runs?per_page=100"] = {"check_runs": [
            {"id": 1, "name": "make-all", "head_sha": NEW, "conclusion": "success"}]}
        self.responses[f"{prefix}/actions/workflows/candidate.yml/runs?head_sha={NEW}&event=push&status=success&per_page=100"] = {
            "workflow_runs": [{"id": 123, "head_sha": NEW, "head_branch": "main"}]}
        def execute(argv, **_kwargs):
            if argv[1] == "api":
                return json.dumps(self.responses[argv[2]])
            destination = Path(argv[argv.index("--dir") + 1])
            (destination / "symphony").write_bytes(b"binary")
            (destination / "manifest.json").write_text(json.dumps(self.good_manifest))
            return ""
        self.fixture.run = execute

    def verify(self, sha=NEW):
        return deploy.Deployer.verify_and_fetch(self.fixture, sha)

    def test_verified_ci_artifact_is_staged_without_rebuilding(self):
        path = self.verify()
        self.assertEqual(path.name, NEW)
        self.assertEqual((path / "symphony").read_bytes(), b"binary")

    def test_invalid_or_unmerged_source_is_rejected(self):
        with self.assertRaisesRegex(deploy.DeploymentError, "full lowercase"):
            self.verify("main")
        self.responses[f"repos/owner/example/compare/{NEW}...main"] = {"status": "diverged"}
        with self.assertRaisesRegex(deploy.DeploymentError, "not on main"):
            self.verify()

    def test_latest_exact_head_check_must_pass(self):
        response = self.responses[f"repos/owner/example/commits/{NEW}/check-runs?per_page=100"]
        response["check_runs"].append({"id": 2, "name": "make-all", "head_sha": NEW, "conclusion": "failure"})
        with self.assertRaisesRegex(deploy.DeploymentError, "exact-head"):
            self.verify()

    def test_checksum_and_compatibility_must_match(self):
        for update, message in [({"sha256": "bad"}, "checksum"),
                                ({"source_sha": OLD}, "source"),
                                ({"database_compatibility": {"reads": [2]}}, "cannot read"),
                                ({"database_compatibility": {"reads": [1], "writes": 2}}, "State format"),
                                ({"runtime": {}}, "runtime requirements")]:
            with self.subTest(message=message):
                previous = self.good_manifest.copy()
                self.good_manifest.update(update)
                with self.assertRaisesRegex(deploy.DeploymentError, message):
                    self.verify()
                self.good_manifest = previous


if __name__ == "__main__":
    unittest.main()
