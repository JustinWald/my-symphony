import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_candidate", ROOT / "package_candidate.py")
package_candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_candidate)


class ArtifactFixturesTests(unittest.TestCase):
    def test_fake_worker_matches_app_server_handshake_and_records_real_usage_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            issues = directory / "issues.json"
            trace = directory / "trace.jsonl"
            issues.write_text(json.dumps([{"id": "1", "state": "Todo"}]))
            messages = [{"method": "initialize", "id": 1}, {"method": "initialized"},
                        {"method": "thread/start", "id": 2}, {"method": "turn/start", "id": 3}]
            result = subprocess.run([sys.executable, str(ROOT / "fake_worker.py"), str(issues), str(trace), "alpha"],
                                    input="\n".join(json.dumps(message) for message in messages) + "\n",
                                    text=True, capture_output=True, check=True, cwd=directory,
                                    env={**os.environ, "SYMPHONY_FIXTURE_MARKER": "synthetic-runtime-marker"})
            replies = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(replies[:3], [{"id": 1, "result": {}},
                {"id": 2, "result": {"thread": {"id": "thread-alpha"}}},
                {"id": 3, "result": {"turn": {"id": "turn-alpha"}}}])
            self.assertEqual(replies[3]["params"]["tokenUsage"]["total"]["inputTokens"], 10)
            self.assertEqual(replies[4], {"method": "turn/completed"})
            self.assertEqual(json.loads(issues.read_text())[0]["state"], "Done")
            observed = json.loads(trace.read_text())
            self.assertEqual(observed["project"], "alpha")
            self.assertEqual(observed["cwd"], str(directory))
            self.assertIn("SYMPHONY_FIXTURE_MARKER", observed["host_runtime_environment"])
            self.assertNotIn("synthetic-runtime-marker", trace.read_text())

    def test_manifest_records_source_and_checksum_of_exact_packaged_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "binary"
            binary.write_bytes(b"immutable executable")
            package_candidate.package(binary, root / "candidate", "a" * 40)
            manifest = json.loads((root / "candidate" / "manifest.json").read_text())
            self.assertEqual(manifest["source_sha"], "a" * 40)
            self.assertEqual(manifest["sha256"], hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertEqual((root / "candidate" / "symphony").read_bytes(), binary.read_bytes())
            with self.assertRaises(ValueError):
                package_candidate.package(binary, root / "bad", "main")


if __name__ == "__main__":
    unittest.main()
