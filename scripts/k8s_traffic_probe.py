"""Run inside the cluster to measure service availability during rollout/undo."""

import json
import time
import urllib.request
from collections import Counter


def main():
    successes = 0
    failures = 0
    versions = Counter()
    print("probe_started", flush=True)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen("http://devops-task:8080/", timeout=2) as response:
                body = json.load(response)
                if response.status != 200:
                    raise ValueError(f"Unexpected status: {response.status}")
                versions[body["version"]] += 1
                successes += 1
        except Exception as error:
            failures += 1
            print(json.dumps({"error": str(error)}), flush=True)
        time.sleep(0.1)
    print(
        json.dumps({"successes": successes, "failures": failures, "versions": versions}), flush=True
    )
    if failures or not {"1.0.0", "1.1.0"}.issubset(versions):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
