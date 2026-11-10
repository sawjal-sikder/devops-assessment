#!/usr/bin/env bash
# Called under deploy.sh's lock. Retain the previous container's exact image/config.
set -Eeuo pipefail
if ! docker container inspect devops-task-previous >/dev/null 2>&1; then
  docker rm -f devops-task 2>/dev/null || true
  echo 'No previous deployment is available to restore.' >&2
  exit 1
fi
docker rm -f devops-task 2>/dev/null || true
docker rename devops-task-previous devops-task
docker start devops-task
for ((attempt=1; attempt<=30; attempt++)); do
  if curl --fail --silent --show-error --max-time 3 http://127.0.0.1:8080/health; then
    printf '\nRollback healthy; restored image: '
    docker inspect --format '{{.Config.Image}}' devops-task
    exit 0
  fi
  sleep 2
done
echo 'Restored container failed its health smoke test.' >&2
exit 1
