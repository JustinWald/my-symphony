from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap-workspace.sh"


class BootstrapTests(unittest.TestCase):
    def test_pins_reviewed_source_and_preserves_issue_branch_and_edits_on_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", *args],
                                               cwd=source, text=True).strip()
            git("init", "--quiet")
            (source / "file").write_text("reviewed source")
            git("add", ".")
            git("commit", "--quiet", "-m", "reviewed")
            reviewed = git("rev-parse", "HEAD")
            (source / "file").write_text("newer unreviewed source")
            git("commit", "--quiet", "-am", "newer")
            workspace = root / "workspace"
            workspace.mkdir()
            command = ["sh", str(SCRIPT), str(source), reviewed]
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
            self.assertEqual((workspace / "file").read_text(), "reviewed source")
            subprocess.run(["git", "checkout", "--quiet", "-b", "issue-1"], cwd=workspace, check=True)
            (workspace / "file").write_text("in-flight changes")
            subprocess.run(command, cwd=workspace, check=True, capture_output=True)
            self.assertEqual((workspace / "file").read_text(), "in-flight changes")
            self.assertEqual(subprocess.check_output(["git", "branch", "--show-current"], cwd=workspace, text=True).strip(), "issue-1")
            wrong_source = subprocess.run(["sh", str(SCRIPT), str(source), git("rev-parse", "HEAD")], cwd=workspace, capture_output=True)
            self.assertNotEqual(wrong_source.returncode, 0)
            self.assertEqual((workspace / "file").read_text(), "in-flight changes")

    def test_rejects_moving_ref_and_nonempty_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "preserve").write_text("existing file")
            for revision in ["main", "a" * 40]:
                result = subprocess.run(["sh", str(SCRIPT), "/not-a-repository", revision], cwd=root, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "preserve").read_text(), "existing file")
            self.assertFalse((root / ".git").exists())


if __name__ == "__main__":
    unittest.main()
