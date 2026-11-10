# DevOps Task — FastAPI

A small service with JSON stdout logs, Prometheus metrics, environment configuration,
and graceful SIGTERM shutdown.

## Run with Docker Compose

```sh
docker compose up --build -d --wait
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/metrics
docker compose logs -f app
docker compose down
```

`GET /` returns:

```json
{"message":"Hello from DevOps Task!","status":"running","version":"1.0.0"}
```

`GET /health` returns HTTP 200 with `{"status":"healthy"}` after startup,
or HTTP 503 with `{"status":"not_ready"}` outside the ready lifecycle.
The service has no external dependencies, so this endpoint serves both liveness
and readiness. During shutdown Uvicorn closes listeners and drains active requests
before running application cleanup.

`GET /metrics` returns Prometheus text exposition with:

| Metric | Meaning |
| --- | --- |
| `http_requests_total` | Completed requests by method, route, and response status |
| `http_errors_total` | Responses with status >= 400, including unhandled 500 errors |
| `http_request_duration_seconds` | Request duration histogram in seconds, including buckets, count, and sum |

All HTTP requests, including probes and scrapes, are measured. A scrape's own
measurement appears on the next scrape. Unknown URLs share the `unmatched` label
to bound metric cardinality. Counters reset on process restart. Run one process
per container and scale containers so each scrape observes a single registry.

## Configuration

All runtime configuration comes from environment variables; defaults work locally.
`.env.example` lists the variables. For a shell run, export variables explicitly;
the Python app does not automatically load `.env` files. Compose reads `.env`
for its documented substitutions.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | Listening port, 1–65535 |
| `HOST` | `0.0.0.0` | Bind address |
| `LOG_LEVEL` | `INFO` | DEBUG, INFO, WARNING, ERROR, or CRITICAL |
| `ENVIRONMENT` | `development` | Environment field in every JSON log |
| `APP_VERSION` | `1.0.0` | Version returned by `/` |
| `SHUTDOWN_TIMEOUT` | `20` | Maximum request drain time in seconds |

Compose publishes host port 8080 to container port 8080. It deliberately fixes
`PORT=8080` so its mapping and health probe stay consistent. Set `LOG_LEVEL`,
`ENVIRONMENT`, and `APP_VERSION` through shell variables or `.env` when using Compose.
The standalone image defaults to `ENVIRONMENT=production`.

## Local development and tests

Use Python 3.14 (the container uses 3.14.4):

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
pytest -q
PORT=8080 LOG_LEVEL=INFO ENVIRONMENT=development python -m app
```

Tests cover endpoint responses, readiness lifecycle, parsed metrics, HTTP errors,
registry isolation, environment validation, JSON logging, and a real subprocess
receiving SIGTERM. The shutdown test needs permission to bind a loopback port.
Start with `python -m app` to apply the environment-based server and logging setup.

## Container design and measured size

The multi-stage Dockerfile installs runtime dependencies into a virtual environment
and copies it and the application into an Alpine runtime. Both stages pin Python
3.14.4 / Alpine 3.23 by version and SHA-256 digest. The shared `requirements.txt` includes application, test, and lint dependencies;
all are installed in the image. Other repository files are excluded from the
build context by an allowlist `.dockerignore`.
The image runs as UID/GID `10001:10001`, has OCI metadata, a Python standard-library
health probe, and an exec-form entrypoint so SIGTERM reaches Uvicorn directly.

**Measured final image size: 192,217,941 bytes (192.2 MB / 183.31 MiB), linux/amd64.**
This is the local image size reported by Docker, not compressed registry transfer
size. Architecture and dependency updates can change it. Reproduce the measurement:

```sh
docker build -t devops-task:1.0.0 .
docker image inspect devops-task:1.0.0 --format '{{.Size}}'
```

Optional build arguments `APP_VERSION` and `VCS_REF` populate OCI version/revision
labels. `APP_VERSION` also supplies the image's runtime version default.

Compose applies a restart policy, a read-only root filesystem, a 16 MB temporary
filesystem, dropped capabilities, no-new-privileges, rotated container logs, and
limits of 0.5 CPU, 128 MiB memory, and 64 PIDs. Its 30-second stop grace period exceeds
the application's default 20-second drain timeout. Keep the stop grace period
larger than `SHUTDOWN_TIMEOUT` when changing these settings.

Implementation references: [Uvicorn server settings](https://uvicorn.dev/settings/)
and the [Prometheus Python client histogram documentation](https://prometheus.github.io/client_python/instrumenting/histogram/).

## CI/CD workflows

Pull requests run linting, tests with an 85% coverage gate and downloadable reports,
Dockerfile/ShellCheck linting, and a Trivy image scan that blocks CRITICAL findings.
Pushes to `production` pass those checks, publish amd64/arm64 images to ECR with commit
SHA and semantic version tags, and deploy via GitHub OIDC and SSM with health-based
rollback. See [AWS and CI/CD setup](docs/terraform.md) for required GitHub variables, IAM policies,
EC2 prerequisites, tagging, rollback behavior, and deployment evidence. No GitHub
secrets or long-lived AWS access keys are required.


## Development and production branches

Use `feature/*` → pull request into `development` → pull request into `production`.

| Event | Checks | Publish and AWS deployment |
| --- | --- | --- |
| Pull request into any branch | Full CI | No |
| Push or merge into `development` | Full CI | No |
| Push or merge into `production` | Full CI, then release | Yes, after checks pass |

Create `development` and `production` branches in GitHub if they do not exist.
Protect both branches with required CI checks and PR reviews. Set the GitHub
`production` environment's deployment branch rule to allow only `production`.
The environment name remains `production`; OIDC trust using the environment
subject remains unchanged. AWS configuration is required only for the production
release job. Development CI runs without AWS credentials.


## Step 3: Terraform on AWS

The `terraform/` root provisions an EC2 deployment target for `staging` or
`production`, with its own VPC, approved-client access to port 8080, instance IAM
permissions, Docker bootstrap, and CloudWatch container logging with retention.
`terraform/bootstrap/` provisions the private/versioned S3 state bucket; the app
uses separate environment state keys and S3 lock files. No static AWS keys are used.

Follow [the Terraform guide](docs/terraform.md) for SSO authentication, initial ECR
publishing, backend setup, plan/apply, health/log checks, and destroy commands.
Both roots pass validation; [offline test output](docs/evidence/terraform-test.txt)
records four mocked plan tests. **No real AWS plan/apply has been run** because no
AWS account/access was provided. These tests are not evidence of an AWS apply.

## Step 4: Local Kubernetes

Manifests under `k8s/` provide two replicas, a rolling update with
`maxUnavailable: 0` / `maxSurge: 1`, startup/liveness/readiness probes, resource
requests/limits, a ConfigMap, an empty Secret template, a ClusterIP Service, and a
CPU HPA (70% utilization, 2–4 replicas). Pods run as UID 10001 with a read-only root
filesystem, dropped capabilities, seccomp, no service-account token, and a small
memory-backed `/tmp`. A five-second preStop delay allows endpoint changes to
propagate before SIGTERM; the 35-second termination grace period leaves time for
the app's 20-second drain. At least three pods must fit during an update.

Install Docker, kind, and kubectl. The measured demonstration uses kind v0.33.0,
Kubernetes v1.35.0, and kubectl v1.35.0. Use a separate kubeconfig to avoid changing
your usual cluster context:

```sh
export KUBECONFIG=/tmp/devops-task-kubeconfig
kind create cluster --name devops-task --image kindest/node:v1.35.0 --config k8s/kind/cluster.yaml

docker build --build-arg APP_VERSION=1.0.0 -t devops-task:1.0.0 .
docker build --build-arg APP_VERSION=1.1.0 -t devops-task:1.1.0 .
kind load docker-image devops-task:1.0.0 devops-task:1.1.0 --name devops-task

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
# Local kind only: its kubelet certificate is not trusted by Metrics Server.
kubectl -n kube-system patch deployment metrics-server --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

kubectl apply -k k8s/
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task port-forward service/devops-task 8080:8080
# In another terminal:
curl --fail http://localhost:8080/health
```

Port-forward is the supported local access method. `k8s/ingress.yaml` is optional
and excluded from Kustomize: it requires an installed controller, a matching
`ingressClassName`, and DNS/hosts setup for `devops.local`. Port-forward binds to a
pod and can end when that pod is replaced; the availability demonstration instead
sends requests through the Service from inside the cluster.

### Secret handling

`secret.example.yaml` contains **no credential values**. The application currently
requires no secrets; an empty Opaque Secret lets the manifest run as-is. If a future
integration requires credentials, create/update it from an ignored, owner-readable
file locally; do not put values in shell command arguments or commit encoded YAML:

```sh
# Create app.secret.env with your actual required keys using your editor; chmod 600.
kubectl -n devops-task create secret generic devops-task-secrets --from-env-file=app.secret.env --dry-run=client -o yaml | kubectl apply -f -
kubectl -n devops-task rollout restart deployment/devops-task
```

Base64 is not encryption. Restrict Kubernetes Secret access with RBAC. The app must
implement any new configuration key before it has an effect. The empty template
is for local testing; omit it from production overlays so reapplying Kustomize does
not overwrite externally managed credentials. Environment changes require pod
replacement. HPA needs Metrics Server; `kubectl top pods -n devops-task` and
`kubectl get hpa -n devops-task` verify the CPU metrics path.

### Rolling update and rollback demonstration

With both versions loaded, run the repeatable demonstration:

```sh
bash scripts/k8s_demo.sh
```

It applies the manifests, starts an in-cluster request probe for 90 seconds, then
runs these commands while requests continue:

```sh
kubectl -n devops-task set image deployment/devops-task app=devops-task:1.1.0
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task rollout undo deployment/devops-task
kubectl -n devops-task rollout status deployment/devops-task --timeout=180s
kubectl -n devops-task logs rollout-probe
```

Actual output from the local run (2026-11-10; full transcript linked below):

```text
deployment.apps/devops-task image updated
deployment "devops-task" successfully rolled out
NAME          READY   UP-TO-DATE   AVAILABLE
devops-task   2/2     2            2
deployment.apps/devops-task rolled back
deployment "devops-task" successfully rolled out
{"successes": 868, "failures": 0, "versions": {"1.0.0": 686, "1.1.0": 182}}
```

Across the update and rollback, all **868 sampled requests succeeded**, and the
probe observed both image versions. HPA reported live CPU utilization with two
replicas. The temporary kind cluster was deleted after collecting evidence.

This is observed availability for the measured request stream, not a guarantee
under all loads or node failures. The probe fails if any request fails or if it
does not observe both versions. [Full captured output](docs/evidence/kubernetes-rollout.txt)
includes rollout status and revision history. HPA metrics are recorded separately
in [cluster evidence](docs/evidence/kubernetes-status.txt).

Clean up after testing:

```sh
kind delete cluster --name devops-task
```

### Production on EKS

Use private worker subnets across Availability Zones, ECR image digests, and an
AWS Load Balancer Controller/ALB with ACM TLS and real DNS in place of port-forward.
Spread replicas across nodes/AZs and add a PodDisruptionBudget. Size requests from
measurements; retain HPA for pods and use Karpenter or Cluster Autoscaler for node
capacity, including surge capacity during releases. Install Metrics Server with
trusted kubelet certificates, without the local insecure-TLS flag. Ship logs with
Fluent Bit/CloudWatch and monitor application metrics.

Store secrets in AWS Secrets Manager with External Secrets or the Secrets Store
CSI driver; use dedicated service accounts with scoped IRSA or EKS Pod Identity
roles for controllers/workloads that access AWS. This app currently needs no AWS
permissions inside its pods. Use RBAC, encrypted secrets at rest, NetworkPolicies,
and a supported network policy provider. Promote signed/scanned image digests
through environment overlays and retain rollout evidence. AWS documents the
[IRSA and Pod Identity options](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html);
Kubernetes documents the [rolling update controls](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).
