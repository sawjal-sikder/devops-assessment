"""Exercise success/failure paths without AWS, Docker, or changing the host."""

import json
import os
import subprocess
from pathlib import Path

import pytest

from scripts.ssm_payload import build_payload

IMAGE = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops@sha256:" + "a" * 64
PREVIOUS = "registry/app:sha-previous"
ROOT = Path(__file__).resolve().parents[1]

FAKE_COMMAND = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(os.environ["FAKE_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
command = Path(sys.argv[0]).name
status = 0
if command == "curl":
    current = state.get("devops-task", {})
    status = 0 if current.get("running") and current.get("image") != os.getenv("FAIL_IMAGE") else 22
elif args[0] == "pull":
    status = 1 if os.getenv("FAIL_PULL") else 0
elif args[:2] == ["container", "inspect"]:
    status = 0 if args[-1] in state else 1
elif args[0] == "inspect":
    item = state[args[-1]]
    print(str(item["running"]).lower() if "Running" in args[2] else item["image"])
elif args[0] == "rm":
    state.pop(args[-1], None)
elif args[0] == "rename":
    state[args[2]] = state.pop(args[1])
elif args[0] == "stop":
    state[args[-1]]["running"] = False
elif args[0] == "start":
    state[args[-1]]["running"] = True
elif args[0] == "run":
    if os.getenv("FAIL_RUN"):
        status = 1
    else:
        state["devops-task"] = {"image": args[-1], "running": True}
elif args[0] != "logs":
    raise RuntimeError(args)
path.write_text(json.dumps(state))
sys.exit(status)
"""


@pytest.mark.parametrize("failure", [None, "health", "pull", "run", "first-health"])
def test_deployment_and_rollback(tmp_path, failure):
    state_file = tmp_path / "state.json"
    initial = (
        {} if failure == "first-health" else {"devops-task": {"image": PREVIOUS, "running": True}}
    )
    state_file.write_text(json.dumps(initial))
    for name in ("docker", "curl"):
        executable = tmp_path / name
        executable.write_text(FAKE_COMMAND)
        executable.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{tmp_path}:{os.environ['PATH']}",
        "FAKE_STATE": str(state_file),
        "DEPLOY_LOCK_FILE": str(tmp_path / "deploy.lock"),
        "SMOKE_ATTEMPTS": "2",
        "SMOKE_INTERVAL": "0",
    }
    if failure in {"health", "first-health"}:
        env["FAIL_IMAGE"] = IMAGE
    if failure == "pull":
        env["FAIL_PULL"] = "1"
    if failure == "run":
        env["FAIL_RUN"] = "1"
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/deploy.sh"), IMAGE],
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
    )
    state = json.loads(state_file.read_text())
    if failure is None:
        assert result.returncode == 0, result.stderr
        assert state["devops-task"] == {"image": IMAGE, "running": True}
        assert state["devops-task-previous"] == {"image": PREVIOUS, "running": False}
    elif failure == "first-health":
        assert result.returncode != 0
        assert state == {}
        assert "No previous deployment" in result.stderr
    else:
        assert result.returncode != 0
        assert state["devops-task"] == {"image": PREVIOUS, "running": True}
        if failure != "pull":
            assert "Rollback healthy" in result.stdout


def test_ssm_payload():
    payload = build_payload(
        {"IMAGE": IMAGE, "AWS_REGION": "us-east-1", "EC2_INSTANCE_ID": "i-0123456789abcdef0"}
    )
    assert payload["DocumentName"] == "AWS-RunShellScript"
    command = payload["Parameters"]["commands"][0]
    assert "get-login-password" in command
    assert "--password-stdin" in command
    assert IMAGE in command
    assert "base64 -d" in command
    subprocess.run(["bash", "-n"], input=command, text=True, check=True)


def test_ssm_rejects_mutable_image():
    with pytest.raises(ValueError):
        build_payload(
            {
                "IMAGE": "registry/app:latest",
                "AWS_REGION": "us-east-1",
                "EC2_INSTANCE_ID": "i-0123456789abcdef0",
            }
        )
