import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "preflight_candidate.py"
SPEC = importlib.util.spec_from_file_location("preflight_candidate", MODULE)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.snapshot = self.root / "snapshot"
        self.snapshot.mkdir()
        self.state = self.snapshot / "0"
        self.state.mkdir()
        with sqlite3.connect(self.state / "management.sqlite3") as connection:
            connection.execute("CREATE TABLE fixture(value TEXT)")
            connection.execute("INSERT INTO fixture VALUES('durable history')")
        (self.state / "runtime-checkpoint.term").write_bytes(b"checkpoint")
        (self.state / "credentials.json").write_text('{"github_token":"PRIVATE"}')
        (self.state / "policy.json").write_text('{"github_token_env":"LIVE_TOKEN","audit":{"enabled":true}}')
        config = self.snapshot / "1"
        config.mkdir()
        (config / "WORKFLOW.md").write_text("Production workflow with hooks and live tracker bindings")
        self.entries = [
            {"source": "/production/state", "copy": str(self.state), "directory": True, "state": True},
            {"source": "/production/config", "copy": str(config), "directory": True, "state": False},
        ]
        self.index()

    def index(self):
        (self.snapshot / "index.json").write_text(json.dumps(self.entries))

    def test_stages_only_database_checkpoint_and_synthetic_configuration(self):
        staged = self.root / "runtime"
        projects = preflight.prepare(self.snapshot, staged, "a" * 40)
        self.assertEqual(len(projects), 1)
        state = staged / "states" / "preflight-0"
        self.assertEqual(sorted(path.name for path in state.iterdir()), ["management.sqlite3", "runtime-checkpoint.term"])
        with sqlite3.connect(state / "management.sqlite3") as connection:
            self.assertEqual(connection.execute("SELECT value FROM fixture").fetchone(), ("durable history",))
        workflow = (staged / "preflight-0.md").read_text()
        self.assertIn("kind: memory", workflow)
        self.assertIn('command: "false"', workflow)
        self.assertIn("delivery_enabled: false", workflow)
        self.assertNotIn("hooks:", workflow)
        self.assertNotIn("LIVE_TOKEN", workflow)
        self.assertFalse(any(path.name == "credentials.json" for path in staged.rglob("*")))
        self.assertEqual((self.state / "runtime-checkpoint.term").read_bytes(), b"checkpoint")

    def test_snapshot_cannot_redirect_to_production_or_symbolic_database(self):
        self.entries[0]["copy"] = str(self.root)
        self.index()
        with self.assertRaisesRegex(preflight.PreflightError, "escapes"):
            preflight.prepare(self.snapshot, self.root / "escaped", "a" * 40)
        self.entries[0]["copy"] = str(self.state)
        self.index()
        (self.state / "management.sqlite3").unlink()
        (self.root / "outside").write_text("production database")
        (self.state / "management.sqlite3").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(preflight.PreflightError, "regular file"):
            preflight.prepare(self.snapshot, self.root / "symlink", "a" * 40)

    def test_no_indexed_management_database_fails_closed(self):
        self.entries[0]["state"] = False
        self.index()
        with self.assertRaisesRegex(preflight.PreflightError, "No operator-indexed"):
            preflight.prepare(self.snapshot, self.root / "empty", "a" * 40)

    def test_namespace_has_only_disposable_writable_bind_and_no_host_credentials(self):
        argv = preflight.sandbox_command("/usr/bin/bwrap", "/release/symphony", "/disposable", "/tools/preflight.py")
        self.assertIn("--unshare-all", argv)
        self.assertIn("--unshare-net", argv)
        self.assertIn("--clearenv", argv)
        self.assertEqual(argv[argv.index("--cap-drop") + 1], "ALL")
        writable = [argv[index + 1:index + 3] for index, value in enumerate(argv) if value == "--bind"]
        self.assertEqual(writable, [["/disposable", "/work"]])
        readonly = [argv[index + 1:index + 3] for index, value in enumerate(argv) if value == "--ro-bind"]
        self.assertNotIn(["/", "/"], readonly)
        self.assertFalse(any(source.startswith(("/home", "/etc", "/run", "/var")) for source, _target in readonly))
        self.assertEqual(argv[argv.index("--remount-ro") + 1], "/")
        self.assertIn("/preflight_candidate.py", argv)

    def test_missing_bubblewrap_never_runs_candidate_unsandboxed(self):
        with patch.object(preflight.shutil, "which", return_value=None):
            with self.assertRaisesRegex(preflight.PreflightError, "no unsandboxed fallback"):
                preflight.preflight({"SYMPHONY_EXTERNAL_EFFECTS": "disabled"}, run=lambda *_args, **_kwargs: self.fail("ran candidate"))

    def test_preflight_runner_receives_isolation_command_and_minimal_environment(self):
        release = self.root / "release"
        release.mkdir()
        binary = release / "symphony"
        binary.write_text("candidate")
        (release / "manifest.json").write_text(json.dumps({"source_sha": "a" * 40}))
        calls = []
        def runner(argv, **kwargs):
            calls.append(argv)
            self.assertEqual(kwargs["env"], {"PATH": "/usr/bin:/bin"})
            self.assertTrue(kwargs["check"])
            writable = Path(argv[argv.index("--bind") + 1])
            self.assertTrue((writable / "projects.json").is_file())
            self.assertFalse((writable / "index.json").exists())
        environment = {"SYMPHONY_EXTERNAL_EFFECTS": "disabled", "SYMPHONY_PREFLIGHT_SNAPSHOT": str(self.snapshot),
                       "SYMPHONY_PREFLIGHT_BINARY": str(binary), "LIVE_TOKEN": "PRIVATE"}
        with patch.object(preflight.shutil, "which", return_value="/usr/bin/bwrap"):
            preflight.preflight(environment, run=runner)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
