#!/usr/bin/env bash
# Run from the repository root after creating kind and loading both app images.
set -euo pipefail
kubectl apply -k k8s/
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task delete pod rollout-probe --ignore-not-found --wait=true
kubectl -n devops-task create configmap rollout-probe \
  --from-file=probe.py=scripts/k8s_traffic_probe.py --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/kind/traffic-probe.yaml
kubectl -n devops-task wait --for=condition=Ready pod/rollout-probe --timeout=120s
sleep 3
kubectl -n devops-task set image deployment/devops-task app=devops-task:1.1.0
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task get deployment devops-task
kubectl -n devops-task rollout undo deployment/devops-task
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task get deployment devops-task
kubectl -n devops-task wait --for=jsonpath='{.status.phase}'=Succeeded pod/rollout-probe --timeout=120s
kubectl -n devops-task logs rollout-probe
kubectl -n devops-task get hpa devops-task
kubectl -n devops-task rollout history deployment/devops-task
