#!/usr/bin/env bash
# Run as root through SSM; the caller authenticates Docker to ECR first.
set -Eeuo pipefail

image=${1:?Usage: deploy.sh IMAGE_DIGEST}
[[ "$image" =~ ^[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]] || {
  echo 'Deployment requires an immutable image digest' >&2
  exit 2
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
smoke_attempts=${SMOKE_ATTEMPTS:-30}
smoke_interval=${SMOKE_INTERVAL:-2}
[[ "$smoke_attempts" =~ ^[1-9][0-9]*$ && "$smoke_interval" =~ ^[0-9]+$ ]]

# Also serialize manual deployments and SSM commands left running by a runner.
exec 9>"${DEPLOY_LOCK_FILE:-/var/lock/devops-task-deploy.lock}"
flock -w 300 9

docker pull "$image"
# Keep the current container untouched if the pull fails.
docker rm -f devops-task-previous 2>/dev/null || true
switched=false
# Invoked indirectly by the EXIT trap; older ShellCheck versions miss this call.
# shellcheck disable=SC2317,SC2329
rollback_on_failure() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$switched" == true ]]; then
    echo 'Deployment failed; restoring previous container/image.' >&2
    docker logs --tail 100 devops-task >&2 || true
    if ! bash "$script_dir/rollback.sh"; then
      echo 'ROLLBACK FAILED or no previous deployment exists; operator action required.' >&2
    fi
  fi
  exit "$status"
}
trap 'rollback_on_failure' EXIT

if docker container inspect devops-task >/dev/null 2>&1; then
  docker rename devops-task devops-task-previous
  switched=true
  docker stop --time 30 devops-task-previous
else
  switched=true
fi

docker run -d --name devops-task \
  --restart unless-stopped --stop-timeout 30 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --cpus 0.5 --memory 128m --pids-limit 64 \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p 8080:8080 \
  -e PORT=8080 -e ENVIRONMENT=production -e LOG_LEVEL=INFO \
  "$image"

for ((attempt=1; attempt<=smoke_attempts; attempt++)); do
  if [[ "$(docker inspect --format '{{.State.Running}}' devops-task)" != true ]]; then
    echo 'New container exited before becoming ready.' >&2
    exit 1
  fi
  if curl --fail --silent --show-error --max-time 3 http://127.0.0.1:8080/health; then
    printf '\nDeployment healthy: %s\n' "$image"
    exit 0
  fi
  sleep "$smoke_interval"
done
echo 'Health smoke test failed.' >&2
exit 1
