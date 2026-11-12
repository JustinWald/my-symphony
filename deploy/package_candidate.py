#!/usr/bin/env python3
"""Stage a commit-addressed, checksummed executable produced by CI."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


def package(binary, output, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("A full source SHA is required")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    staged = output / "symphony"
    shutil.copy2(binary, staged)
    staged.chmod(0o500)
    manifest = {
        "source_sha": sha,
        "sha256": hashlib.sha256(staged.read_bytes()).hexdigest(),
        "target": "linux_x86_64",
        "runtime": {"kind": "burrito", "tested_on": "ubuntu-24.04", "bundled_erlang": True},
        "database_compatibility": {"reads": [1], "writes": 1, "binary_rollback_tested": False},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    package(*sys.argv[1:])
