#!/usr/bin/env python3
"""Local Codex protocol fixture used only by packaged-artifact smoke tests."""
import json
import os
from pathlib import Path
import sys


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    issues_path, trace_path, project = sys.argv[1:4]
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            emit({"id": message["id"], "result": {}})
        elif method == "thread/start":
            emit({"id": message["id"], "result": {"thread": {"id": f"thread-{project}"}}})
        elif method == "turn/start":
            emit({"id": message["id"], "result": {"turn": {"id": f"turn-{project}"}}})
            emit({"method": "thread/tokenUsage/updated", "params": {
                "tokenUsage": {"total": {"inputTokens": 10, "outputTokens": 2, "cachedInputTokens": 0}}}})
            issues = json.loads(Path(issues_path).read_text())
            for issue in issues:
                issue["state"] = "Done"
            temporary = Path(issues_path + ".next")
            temporary.write_text(json.dumps(issues))
            os.replace(temporary, issues_path)
            with Path(trace_path).open("a") as trace:
                host_names = [name for name in os.environ if name.startswith(("SYMPHONY_", "__BURRITO"))
                              or name in ("ROOTDIR", "BINDIR", "RELEASE_ROOT", "RELEASE_SYS_CONFIG")]
                trace.write(json.dumps({"project": project, "cwd": os.getcwd(), "host_runtime_environment": host_names}) + "\n")
            emit({"method": "turn/completed"})
            return


if __name__ == "__main__":
    main()
