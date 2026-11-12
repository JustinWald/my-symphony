#!/usr/bin/env python3
"""Review branch protection by default; apply only with explicit operator approval."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="JustinWald/my-symphony")
    parser.add_argument("--approve", action="store_true", help="apply protection using the current GitHub identity")
    arguments = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository):
        parser.error("invalid repository")
    policy = Path(__file__).with_name("main-protection.json")
    value = json.loads(policy.read_text())
    print(json.dumps({"repository": arguments.repository, "branch": "main", "protection": value}, indent=2))
    if arguments.approve:
        subprocess.run(["gh", "api", "--method", "PUT",
                        f"repos/{arguments.repository}/branches/main/protection", "--input", str(policy)], check=True)
    else:
        print("Dry run. Pass --approve only after reviewing this policy.")


if __name__ == "__main__":
    main()
