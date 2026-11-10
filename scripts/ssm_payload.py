"""Serialize deployment scripts and nonsecret arguments into an SSM request."""

import base64
import json
import os
import re
import shlex
from pathlib import Path


def build_payload(environment):
    image = environment["IMAGE"]
    region = environment["AWS_REGION"]
    instance = environment["EC2_INSTANCE_ID"]
    if not re.fullmatch(r"[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}", image):
        raise ValueError("IMAGE must be an immutable registry digest")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d", region):
        raise ValueError("Invalid AWS_REGION")
    if not re.fullmatch(r"i-[a-f0-9]{8,17}", instance):
        raise ValueError("Invalid EC2_INSTANCE_ID")
    registry = image.split("/", 1)[0]
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "umask 077",
        "work_dir=$(mktemp -d /tmp/devops-deploy.XXXXXX)",
        'export DOCKER_CONFIG="$work_dir/docker"',
        'mkdir -p "$DOCKER_CONFIG"',
        "trap 'rm -rf -- \"$work_dir\"' EXIT",
    ]
    for name in ("deploy.sh", "rollback.sh"):
        content = base64.b64encode(Path("scripts", name).read_bytes()).decode()
        commands.append(f'printf %s {shlex.quote(content)} | base64 -d > "$work_dir/{name}"')
    # The EC2 instance profile supplies ECR pull credentials; no token is sent by GitHub.
    commands.extend(
        [
            f"aws ecr get-login-password --region {shlex.quote(region)} "
            f"| docker login --username AWS --password-stdin {shlex.quote(registry)}",
            f'bash "$work_dir/deploy.sh" {shlex.quote(image)}',
        ]
    )
    return {
        "DocumentName": "AWS-RunShellScript",
        "DocumentVersion": "1",
        "InstanceIds": [instance],
        "TimeoutSeconds": 120,
        "Comment": "DevOps Task deployment with health check and automatic rollback",
        "Parameters": {"commands": ["\n".join(commands)], "executionTimeout": ["540"]},
    }


if __name__ == "__main__":
    print(json.dumps(build_payload(os.environ)))
