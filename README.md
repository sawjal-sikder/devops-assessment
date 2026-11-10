# DevOps Task — FastAPI

A small service with JSON stdout logs, Prometheus metrics, environment configuration,
and graceful SIGTERM shutdown.

## Prerequisites

Run the commands from the repository root. Use a Linux host for the complete
assessment, especially host exporters and the health script.

| Part | Prerequisites |
| --- | --- |
| App / observability | Git, Docker Engine, Docker Compose v2, a browser, free ports 8080 (app-only) and 3000 (Grafana). Allow about 4 GiB of Docker memory for the full stack and additional disk for images and retained data. Docker Desktop observes its Linux VM rather than the desktop host. |
| Tests | Python 3.14, pip/venv, and the Linux utilities listed below; `pip install -r requirements.txt` installs test/lint tools too. |
| Health script | Bash 4+, Linux procfs, GNU coreutils (`df`, `timeout`, `stat`, etc.), `awk`, `procps` (`ps`), and util-linux (`flock`). On Debian/Ubuntu: `sudo apt-get install bash coreutils gawk procps util-linux`. systemd is needed only for the provided timer. |
| Terraform / AWS | Terraform >= 1.10 (tested with 1.14.0), AWS CLI v2, and an authorized AWS account/SSO or OIDC identity. AWS is optional for all local steps. |
| Kubernetes | Docker, kind v0.33.0, kubectl v1.35.0, and the provided Kubernetes v1.35.0 kind node image. |

The app-only Compose file and monitoring Compose file are **separate setups**:
use `docker compose up --build -d --wait` for the app on 8080, or
`docker compose -f docker-compose.monitoring.yml up --build -d` for the app plus
observability with only Grafana published. The monitoring file requires your
Grafana username/password in the ignored `.env`; it has no default credentials.

Runbook links: [local app](#run-with-docker-compose),
[tests](#local-development-and-tests), [AWS/Terraform](#step-3-terraform-on-aws),
[Kubernetes](#step-4-local-kubernetes),
[monitoring and dashboard login](#step-5-local-monitoring-and-logging), and
[Linux automation](#step-6-linux-health-automation).

## Architecture

The arrows below show release and data flow. Local Kubernetes and EC2 are two
separate deployment targets; the default monitoring file scrapes the Compose app,
not the Kubernetes pods or the remote EC2 instance.

```mermaid
flowchart TB
  Commit[Code commit / pull request] --> PR[CI: lint, tests, coverage, Docker build, Trivy CRITICAL gate]
  PR --> Merge[Reviewed merge: development to production]
  Merge --> Checks[Repeat CI on production push]
  Checks --> Build[Buildx: amd64 + arm64, cached layers, SHA + semantic tags]
  Build --> ECR[Amazon ECR: immutable deployment digest]
  Build --> OIDC[GitHub OIDC: temporary AWS credentials]
  OIDC --> SSM[SSM: deploy, health smoke test, automatic rollback]
  ECR --> EC2[EC2: Docker app + retained previous container]
  SSM --> EC2
  TF[Terraform: staging / production] --> EC2
  TF --> State[S3: encrypted versioned state + lock files]
  EC2 --> CW[CloudWatch container logs + retention]

  Local[Local Docker image builds: 1.0.0 and 1.1.0] --> Load[kind load docker-image]
  Load --> Kube[Kubernetes Deployment: 2+ replicas, rolling update, HPA]
  Manifests[k8s manifests: config, secret template, probes, resources] --> Kube
  Kube --> Service[ClusterIP Service + port-forward]
  Kube --> Undo[kubectl rollout undo]

  App[Local Compose app] -->|metrics| Prom[Prometheus + recording / alert rules]
  Host[Linux host] --> Node[Node Exporter]
  Node -->|host metrics| Prom
  Docker[Docker containers] --> Cad[cAdvisor]
  Cad -->|container metrics| Prom
  App -->|JSON stdout| Docker
  Docker -->|Docker discovery + log streams| Alloy[Grafana Alloy]
  Alloy --> Loki[Loki + retention compactor]
  Prom -->|PromQL queries| Grafana[Grafana: provisioned data sources + 3 dashboards]
  Loki -->|LogQL queries| Grafana
```

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

## Step 5: Local monitoring and logging

The standalone `docker-compose.monitoring.yml` runs the app and all six mandatory
components: **Prometheus, Grafana, Loki, Grafana Alloy, Node Exporter, and cAdvisor**.
Use it by itself, rather than merging it with the main Compose file (which
publishes the app's port). On native Linux with Docker Engine:

```sh
# If .env does not exist yet:
cp -n .env.example .env
chmod 600 .env
# Edit .env and set a unique GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD.
# Both are required; there are no default admin credentials in Compose.
docker compose -f docker-compose.monitoring.yml up --build -d
```

Open **http://127.0.0.1:3000** and sign in with your `.env` credentials. This
workspace's local `.env` has a generated password; it is ignored by Git. In
Grafana open **Dashboards → DevOps Task**. Data sources and all three dashboards
are provisioned from `monitoring/grafana/`; no UI setup or dashboard import is
needed. Allow 30–60 seconds for discovery/scrapes and rate calculations.

Only Grafana publishes a host port, bound to loopback. The app, Prometheus, Loki,
Alloy, Node Exporter, and cAdvisor use an `internal: true` Docker network with no
published ports. Grafana also joins a frontend bridge so Docker can forward its
localhost port. Metrics and logs stay on the internal network. To verify the app
without publishing it:

```sh
docker compose -f docker-compose.monitoring.yml exec -T app python -c 'import urllib.request; print(urllib.request.urlopen("http://app:8080/health").read().decode())'
```

Image pins are explicit in Compose: Prometheus `v3.16.0`, Grafana `13.3.0`, Loki
`3.7.9`, Alloy `v1.21.3`, Node Exporter `v1.12.1`, and cAdvisor `0.60.6`.
The local app uses `devops-task:1.0.0`. Grafana has a 1 GiB limit to allow dashboard-rendering headroom.
All seven containers have memory limits, a restart policy, and rotated Docker JSON logs (10 MB × 3 files per container).
This monitoring deployment deliberately uses Docker `json-file` logging; the AWS
EC2 deployment uses CloudWatch instead.

### Collection and retention

Prometheus scrapes every 15 seconds: the app's `/metrics`, Node Exporter, and
cAdvisor, plus Prometheus/Loki/Alloy self-metrics. Rules evaluate every 15 seconds.
Prometheus retains **7 days**, with a **2 GB** TSDB retention-size threshold;
whichever threshold is reached first expires older blocks. The size threshold is
not a hard filesystem quota: WAL/head data and block cleanup need extra space.

Loki uses a single-node filesystem/TSDB v13 store with **168-hour (7-day)** retention
and 24-hour index periods. Its compactor runs every 10 minutes, with retention
enabled and a two-hour deletion delay; physical deletion is asynchronous. Loki
has no disk-size cap here, so watch host filesystem usage. Both retain data in
named volumes. Grafana's database and Alloy's Docker log positions are also
persisted in named volumes. See the
[Loki retention documentation](https://grafana.com/docs/loki/latest/operations/storage/retention/).

Alloy uses Docker service discovery without a project filter and tails **all
running containers**, including containers outside this Compose project. Its
Docker source unwraps the Docker transport; the JSON stage parses the app's
original structured message. Do not add another Docker envelope parser to this
source. Indexed log labels are stable `project`, `service`, and (for this app)
`level`. Loki may also derive the bounded `service_name` label. Standalone
containers fall back to `project="standalone",service="docker"`. Container IDs,
request IDs, raw URLs, timestamps, and messages are not indexed labels.

App `level` has a small bounded set of values. Request `path` and `status_code`
remain in the original JSON and can be extracted with LogQL `| json` at query time;
this avoids a stream for every path/status combination. The app already normalizes
unknown routes to `unmatched`. A future route containing user IDs should likewise
use a route template. Prometheus keeps only the useful Compose project/service
labels from cAdvisor's container labels. This limits label cardinality while
preserving per-container metrics through cAdvisor's `name`/`id` series.
See [Alloy's Docker log source](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.docker/).

### Provisioned dashboards and screenshots

These are actual screenshots from this local stack, not mockups. The sample
traffic included 225 intentional HTTP 404 responses among 3,367 requests; no
server failure was injected. The dashboards count HTTP >= 400 as errors, matching
the app's metrics. Probe and scrape traffic are excluded from application rate,
error, and latency panels. Percentiles are histogram estimates with the app's
configured buckets, not exact latency samples.

**Application:** request rate, error percentage, errors/second by response status,
p50/p95/p99 latency, and scrape availability. Its Loki failed-request/exception log panel is alongside the
latency/error metrics so the same time window can be investigated.

![Application metrics and correlated JSON logs](docs/screenshots/application.png)

**Host:** CPU utilization, available-memory utilization, filesystem usage/free
space, disk I/O, and network throughput from Node Exporter.

![Host metrics from Node Exporter](docs/screenshots/host.png)

**Containers:** per-container CPU cores, working-set memory, actual configured
memory limit, memory as a percentage of that limit, and network throughput from
cAdvisor. All stack containers have finite limits; zero/unbounded sentinel limits
are excluded from the percentage panel.

![Container CPU and memory relative to limits](docs/screenshots/containers.png)

### Alert rules and threshold choices

Four Prometheus alerts live in `monitoring/prometheus/alerts.yml`. Recording rules
in `rules.yml` compute five-minute application rates. These are starting thresholds
for this small service, to be tuned against real traffic and service objectives.

| Alert | Condition | `for` | Reasoning |
| --- | --- | --- | --- |
| AppInstanceDown | App scrape `up == 0` | 1 minute | Four missed 15-second scrapes indicate sustained unavailability while allowing a short restart or transient connection failure. `/health` can then distinguish app readiness from scrape access problems. |
| HighApplicationErrorRate | HTTP >= 400 exceeds 5% over five minutes, with > 1 request/second | 5 minutes | A sustained error fraction merits investigation; the traffic floor prevents one failed low-volume request from paging. Includes client errors, so inspect status codes before concluding there is a server bug. Health/scrape requests are excluded. |
| HostDiskUsageHigh | Writable real filesystem exceeds 80% usage, based on available bytes | 10 minutes | Leaves approximately 20% headroom for logs/TSDB/WAL growth and filters brief temporary writes. Pseudo-filesystems and read-only mounts are excluded. |
| ContainerMemoryNearLimit | Working set exceeds 90% of an exported finite memory limit | 5 minutes | Less than 10% headroom raises OOM risk. Five minutes avoids most short allocation/cache spikes; zero and unbounded sentinel limits are excluded. |

The error alert uses both a five-minute rate window and a five-minute pending
period, so a short demonstration spike need not reach firing state. The rules are
loaded and evaluated by Prometheus; notifications are **not dispatched** without
an Alertmanager/receiver, which is outside this six-component stack. Inspect rule
state through Grafana Explore using the Prometheus expression `ALERTS`, or through
the authenticated datasource proxy:
`http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/rules`.

Rule unit tests cover all four firing conditions and confirm the high-error alert
stays pending before its duration elapses. They also verify low-traffic and
unbounded-memory exclusions:

```sh
docker compose -f docker-compose.monitoring.yml exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose -f docker-compose.monitoring.yml exec -T -w /etc/prometheus prometheus promtool test rules alerts.test.yml
```

### Finding the cause of an error spike

1. On **Application**, drag over the spike to select its time interval. Compare
   request volume, error percentage, and the status-code series. Rising 404s often
   indicate a client/route problem; rising 500s point toward request processing.
   Compare p95/p99 latency to see whether errors coincide with slower requests.
2. Read the adjacent Loki panel for that same interval. Open it in Explore for
   filters. Find all failed requests with:

   ```logql
   {project="devops-monitoring",service="app"} | json | status_code >= 400
   ```

   Narrow to a route using an extracted field (a query filter, not an indexed path
   label):

   ```logql
   {project="devops-monitoring",service="app"} | json | path="unmatched" | status_code=404
   ```

   For exceptions or application error messages, use:

   ```logql
   {project="devops-monitoring",service="app",level="ERROR"} | json
   ```

   A completed failed request is currently logged at INFO with its `status_code`,
   so filtering only `level="ERROR"` would miss expected 4xx responses. Unhandled
   exceptions produce separate ERROR logs with an exception field. In the sample
   screenshots, the deliberate missing route produces `path="unmatched"` and
   `status_code=404`; this is a controlled client error, not an application crash.
3. Open **Containers** at the same time range. Check whether app CPU saturated or
   working-set memory approached its limit, and compare the other containers.
   Check container restart/state using `docker compose -f
   docker-compose.monitoring.yml ps` and logs if metrics disappear.
4. Open **Host** to correlate host CPU, available memory, disk space/I/O, and
   network throughput. If multiple containers struggle together, host pressure is
   more likely than an isolated request handler problem.
5. For missing logs, inspect Alloy's logs and Loki readiness; for missing metrics,
   query `up` in Grafana Explore and inspect exporter/Prometheus logs with
   `docker compose -f docker-compose.monitoring.yml logs --tail=100 SERVICE`.
   Apply the appropriate app/config/resource fix and confirm error rate and
   latency return to baseline. Keep the same time window as incident evidence.

To reproduce the local spike and check the full collection path:

```sh
docker compose -f docker-compose.monitoring.yml exec -T app python - --duration 180 < scripts/monitoring_traffic.py
python3 scripts/verify_monitoring.py
```

The verifier uses environment variables or the ignored `.env` to authenticate to
Grafana. It checks all six scrape targets, every dashboard metric expression,
provisioning status, logs from all seven containers, JSON/status filtering, and
healthy alert rules. [Captured verification output](docs/evidence/monitoring.txt)
is included. CI validates Compose, dashboard JSON, all three collector configs,
alert tests, and shell scripts. Screenshot layouts may change across Grafana
versions; committed JSON remains the source of truth.

### Host access and security boundaries

| Component | Host access granted | Purpose and limits |
| --- | --- | --- |
| Node Exporter | Host PID namespace; `/:/host:ro,rslave`; no added capabilities; read-only root filesystem and a 1 MB `/textfile` tmpfs | Reads the host's proc/sys/filesystem data. `rslave` lets host mount changes be observed without propagating container mounts back. Host PID access exposes process metadata, so this is a trusted observer. |
| cAdvisor | `privileged: true`; read-only mounts of `/` at `/rootfs`, `/sys`, `/var/run`, and `/var/lib/docker` | Reads cgroups, container metadata/socket, and storage information on this Linux/cgroup-v2 host. Privileged mode grants broad kernel/device access and is a local assessment convenience, not a strong isolation boundary. No `/dev/kmsg` or `/dev/disk` mount was needed for the required CPU/memory metrics. |
| Alloy | Runs as root with `/var/run/docker.sock:ro` | Docker discovery and log-stream access for all containers. A read-only socket mount does **not** make Docker's API read-only; possession of this socket can control Docker and is effectively host-level authority. |

Node Exporter's normal network collector would observe the exporter's bridge
namespace. To keep its HTTP endpoint off the host while collecting actual **host**
network usage, `monitoring/node-exporter/entrypoint.sh` reads
`/host/proc/1/net/dev` every five seconds and exposes counters through the standard
Node Exporter textfile collector. The dashboard uses these
`node_host_network_*_bytes_total` counters, excluding loopback/Docker bridge/veth
interfaces to avoid repeatedly counting the same traffic. CPU/memory/disk metrics
use Node Exporter's regular collectors with the host proc/sys/rootfs paths.
`node_textfile_scrape_error` and the textfile modification time help diagnose a
failed collector. No host-network mode or extra published exporter port is used.

These mounts expose host metadata, files, and Docker logs. Run this trusted stack
on a dedicated development Linux host. Docker Desktop reports metrics for its
Linux VM, not the macOS/Windows host; rootless Docker or different storage paths
may require mount/permission changes. For a shared/production environment, reduce
cAdvisor privileges after testing on that platform, replace direct Docker socket
access with an API-filtering proxy, and protect Grafana with TLS/authentication and
Loki with an authenticating gateway. Loki authentication is disabled only because
it has no public endpoint in this isolated local setup. Do not put credentials
or sensitive request payloads in application logs.

Grafana initializes admin credentials from the environment on first startup; its
persisted database retains password changes. Merely editing `.env` does not rotate
an existing admin account—use Grafana's account/admin password-reset procedure.
`.env` must remain ignored and readable only by its owner.

Stop the stack while retaining metrics/logs/dashboards:

```sh
docker compose -f docker-compose.monitoring.yml down
```

For a deliberate complete local reset, append `--volumes`; this permanently deletes
this stack's metrics, logs, Grafana database, and Alloy positions. Save evidence
first. The application-only Compose setup remains available separately.


## Step 6: Linux health automation

`scripts/system_health.sh` is an executable Bash script with `set -euo pipefail`.
It takes a CPU counter sample (one second by default), computes memory usage from
`MemAvailable`, reports every mount in `/proc/self/mounts`, reads 1/5/15-minute load
averages, and lists the top five processes by resident memory. It records process
names rather than full command lines to avoid copying credential arguments into
logs. Run it on the host for host-wide results; a container/sandbox only exposes
its own process/mount view. The diagnostic `--proc-root` changes procfs inputs;
`ps` still reports the script's current PID namespace.

```sh
./scripts/system_health.sh --help
./scripts/system_health.sh --disk 80 --cpu 90 --mem 85
./scripts/system_health.sh --json --log-file /tmp/health_log.txt
```

The script prints a snapshot and appends it to `./health_log.txt` by default.
`--json` writes one complete JSON object per line to stdout **and** the log; human
warnings go to stderr. Keep one output format per log file. JSON includes the UTC
timestamp, hostname, status/exit code, CPU/memory/load, filesystem records,
processes, configured thresholds, and alert messages. Quotes, backslashes, and
control characters in names are escaped. Byte counts are numeric; process RSS is
in KiB and percentages are numeric (not strings).

| Metric | Warning default | Critical default |
| --- | --- | --- |
| CPU | 90% | 95% |
| Memory | 85% | 95% |
| Writable filesystem | 80% | 95% |

Flags `--cpu`, `--mem`, and `--disk` change warning thresholds; use
`--critical-cpu`, `--critical-mem`, and `--critical-disk` for critical thresholds.
Thresholds are inclusive integer percentages, 1–100, and warning cannot exceed
critical. For example:

```sh
./scripts/system_health.sh --json --cpu 85 --critical-cpu 95 --mem 80 --critical-mem 90 --disk 75 --critical-disk 90 --sample-seconds 2 --log-file /tmp/health_log.txt
```

Exit codes are **0 healthy**, **1 warning**, and **2 critical**. The highest
observed severity wins. All threshold alerts begin `[WARNING]`; critical ones
also include `[CRITICAL]`. Invalid options, missing utilities/procfs, failures to
read/write/lock logs, and collection failures also return 2. A filesystem stat
failure is recorded with null values and an error, not silently treated as
healthy. Failures before a usable snapshot exists may produce stderr without a
JSON record. Scripts using `set -e` must handle the intentional nonzero outcomes:

```sh
health_status=0
./scripts/system_health.sh --json --log-file /tmp/health_log.txt > /tmp/current-health.json || health_status=$?
printf 'Health exit code: %s\n' "$health_status"
python3 -m json.tool /tmp/current-health.json
```

All mounts are retained in the report, including read-only mounts and virtual
filesystems. Read-only snapshots such as squashfs may normally show 100%; disk
alerts therefore apply only to writable filesystems with capacity. Procfs, sysfs,
cgroups, namespace mounts, and similar non-storage filesystems use null capacity
values with `capacity_applicable=false`. Zero-capacity filesystems have null usage.
`df` is bounded by `--df-timeout` (default five seconds per mount), so an unresponsive
remote filesystem is reported as a collection error. Use appropriate host access
(root via the systemd service) to inspect protected mount paths; an unprivileged
run can correctly return 2 for inaccessible mounts. Load averages are reported
without a fixed threshold because interpretation depends on CPU count/workload.

### Rotation and concurrency

The default active log threshold is **1 MiB**, with five numbered archives
(`health_log.txt.1` newest through `.5` oldest). Before an append would exceed the
threshold, the script shifts archives, discards the oldest by replacement, and
starts a new active file. Override with `--max-log-bytes` and `--keep-logs`.
With a stable configuration this uses at most six MiB of snapshot logs plus the
small `.lock` file. A pre-existing oversized log is retained until its archive
ages out; lowering the limit does not truncate old records. A single snapshot
larger than the limit returns 2 without appending; increase the limit on hosts
with many mounts.

A per-log `flock` serializes collection, append, and rotation (ten-second lock
wait). The persistent `.lock` file is not a stale-lock problem: the kernel releases
the lock when the process exits. Do not unlink it while writers are running.
Log/lock/archive symlinks are refused. Use a trusted, owner-controlled directory
and avoid external writers that bypass this locking protocol. New logs use umask
027; the production log directory below is owned by root and mode 0750.

### Run every five minutes with systemd

From the repository root, install only the reviewed script and unit files:

```sh
sudo install -d -m 0755 /opt/devops-task/scripts
sudo install -m 0755 scripts/system_health.sh /opt/devops-task/scripts/system_health.sh
sudo install -m 0644 systemd/system-health.service /etc/systemd/system-health.service
sudo install -m 0644 systemd/system-health.timer /etc/systemd/system-health.timer
sudo systemctl daemon-reload
sudo systemctl enable --now system-health.timer
sudo systemctl start system-health.service
systemctl list-timers system-health.timer
sudo journalctl -u system-health.service -n 20
sudo tail -n 1 /var/log/system-health/health_log.txt
```

The timer runs on wall-clock minutes 00/05/10/etc. and catches up once after a
missed schedule (`Persistent=true`). systemd creates `/var/log/system-health`.
The service has a 120-second overall timeout, no new privileges, and only the
DAC read/search capability for protected host paths. It runs as root to inspect
host mounts but does not install software or change services. It does not create
a private mount/PID view, which would change the host metrics being observed.
Exit 1 is accepted as a completed warning run (`SuccessExitStatus=1`); exit 2
marks the service failed for monitoring. The timer can invoke it again at the
next interval. If collection consistently approaches the timeout on a large
server, tune it along with per-filesystem timeouts. Do not schedule a duplicate
cron job for the same service.

To uninstall the schedule, disable the timer first:

```sh
sudo systemctl disable --now system-health.timer
sudo systemctl stop system-health.service
```

To test just the health script's deterministic cases:

```sh
pytest -q tests/test_system_health.py
```

Tests exercise healthy/warning/critical results, threshold boundaries, read-only
and zero-capacity mounts, JSON escaping, failed filesystem collection, rotation,
symlink refusal, size limits, flag validation, and waiting for another log writer.
CI's ShellCheck step covers this script too. Full-suite results are captured in
[test evidence](docs/evidence/test-results.txt).

## Design Decisions

- **Alpine runtime:** a pinned Python/Alpine image keeps the Dockerfile small and
  supplies the standard-library health probe. Distroless would remove more tools
  but complicate Python packaging and local debugging. The multi-stage virtualenv
  separates installation from the runtime filesystem. Per the requested merge,
  there is one requirements file, so test/lint tools are also in the image; this
  increases size and the dependency surface compared with runtime-only installs.
- **EC2 and local Kubernetes:** EC2 provides a small, understandable AWS target
  without a managed orchestrator/control plane. It requires OS maintenance and
  has single-instance downtime during replacement. ECS would reduce container
  scheduling/host management work; EKS would fit a larger Kubernetes platform but
  adds cost and operational complexity. kind demonstrates orchestration locally
  without claiming a production Kubernetes installation.
- **Tagging and promotion:** full SHA tags trace code; unique semantic prerelease
  tags trace each build/rerun. Deployment uses the returned digest, so mutable tag
  updates cannot change the chosen payload. The same digest is retained for
  recovery. ECR SHA tags can move on reruns; semantic tags stay unique.
- **Secrets and identity:** GitHub uses OIDC and EC2 uses an instance profile;
  neither needs stored AWS access keys. Grafana credentials live in ignored local
  environment configuration. The current app has no secrets; Kubernetes commits
  only an empty template, with real values supplied outside Git.
- **Metrics and labels:** one app process per container gives a consistent local
  metrics registry. Unknown paths collapse to `unmatched`. Loki indexes stable
  service/project/level values and parses paths/status codes at query time, keeping
  stream cardinality low. Retention and log rotation bound historical growth;
  working-set memory is compared against configured cgroup limits.
- **Small local storage footprint:** single-node Loki/filesystem and Prometheus
  named volumes are easy to reproduce but do not offer replicated durable storage.
  The Docker socket and cAdvisor privileges are deliberate local trade-offs,
  documented above, rather than a production security model.

## Deployment & Rollback Strategy

Feature changes reach `development` through reviewed pull requests. PRs and
`development` pushes run CI without AWS access. A reviewed merge into `production`
runs the checks again; required branch checks and the production environment's
branch restriction should prevent bypassing this process. Configure required
reviewers if the release policy requires manual approval.

After CI succeeds, Buildx publishes amd64/arm64 images with cached layers, SHA and
semantic tags, and the image version/revision labels. The release role obtains
short-lived AWS credentials via OIDC and sends an SSM command to EC2. The host
locks deployments, authenticates to ECR with its own role, and pulls the exact
digest **before** stopping the current service. It retains the previous container
with its image/configuration, starts the new one, and polls `/health` up to 30
times. No SSH key, public SSH port, or repository checkout is needed on EC2.

Startup or health failure triggers the EXIT trap in `scripts/deploy.sh`, which
invokes `scripts/rollback.sh` to restore the previous container and recheck health.
The workflow remains failed even when rollback succeeds, preserving evidence of
the failed release. Image pull failure leaves the current service running; first
installation has no prior version to restore. CI and host locks prevent concurrent
switches. Forced process/host termination can defeat a shell trap; inspect the
SSM command before retrying an interrupted workflow. Retain the deployment
artifact's command output and digest before destroying resources.

For an operator-selected rollback, retrieve a known-good digest from retained
release evidence and use the same tested SSM deployment path with authorized AWS
credentials (see [AWS authentication](docs/terraform.md)):

```sh
export AWS_REGION=us-east-1
export EC2_INSTANCE_ID=YOUR_REAL_INSTANCE_ID
export IMAGE=YOUR_REGISTRY/REPOSITORY@sha256:YOUR_REAL_64_CHARACTER_DIGEST
python3 scripts/ssm_payload.py > /tmp/rollback-command.json
command_id=$(aws ssm send-command --cli-input-json file:///tmp/rollback-command.json --query 'Command.CommandId' --output text)
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$EC2_INSTANCE_ID"
```

Fill in the real values; command submission is asynchronous. Inspect/poll until
`Status` is `Success` and the health-test output confirms restoration. This
redeploys the old digest and retains the displaced container using the same
rollback protections. Reverting the faulty code through a PR is also needed to
keep source and the deployed behavior consistent.

The single EC2 port switch has a short interruption; zero downtime is demonstrated
separately by Kubernetes's two replicas, readiness checks, and zero-unavailable
rolling strategy. `kubectl rollout undo` restores a retained pod-template revision;
image digests should be immutable in a production overlay. The recorded local
update/undo served 868 sampled requests without failure. ConfigMap/Secret contents
are not versioned by `rollout undo`; version them separately when a release changes
configuration. Database migrations would require their own backward-compatible
strategy; this service has no database.

## Security Considerations

Keep `.env`, local tfvars/backend files, state, plans, kubeconfigs, and real Secret
values outside Git. `.env.example` intentionally has no Grafana password. Use SSO
locally and tightly scoped OIDC trust for GitHub's production environment. The EC2
role can pull only its ECR repository and write only its log group, with the SSM
channel permissions needed for deployments. State is encrypted, private,
versioned, and locked in S3; restrict backend object access by environment.

The Dockerfile pins its base digest, runs as UID 10001, and uses exec-form startup.
Compose/Kubernetes apply resource budgets, read-only filesystems, dropped app
capabilities, and no privilege escalation. EC2 requires IMDSv2 and only exposes
8080 to approved CIDRs; administrative access is through SSM. Add TLS and a load
balancer before using this direct-HTTP assessment target for public traffic.
Locally only Grafana is published by the monitoring stack, on loopback; the
app-only Compose setup separately exposes 8080. Exporter host access and Docker
socket authority are described in the monitoring security table.

PR and production CI fail on CRITICAL application-image findings, including
unfixed ones. They use read-only PR permissions and no AWS credentials for PR
code. Scanning is point-in-time and presently covers the CI-built amd64 app image;
arm64 and all observability images should receive independent scheduled scans
and update review. A passing scan does not make an image vulnerability-free.
Pin third-party action revisions and sign/verify release images as a next step.
Never log credentials or request payload secrets; health logs include process
names without their full command arguments. Protect health log directories from
untrusted users, especially when the timer runs as root.

## Rough Monthly AWS Cost Estimate

Illustrative **us-east-1, Linux On-Demand, 730 hours/month**, checked against AWS
pricing on **2026-11-10**. This estimates the provisioned **single EC2 app target**,
not a highly available production platform. The full observability stack remains
on the local workstation; it would need separate capacity/budget in AWS.

| Item and assumption | Approximate monthly USD |
| --- | ---: |
| One t3.micro at $0.0104/hour × 730 | $7.59 |
| One public IPv4 at $0.005/hour × 730 | $3.65 |
| 8 GB gp3 root volume at $0.08/GB-month | $0.64 |
| CloudWatch: 2 GB log ingestion at $0.50/GB | $1.00 |
| CloudWatch: assumed 1 GB average retained/compressed logs at $0.03/GB-month | $0.03 |
| ECR: assumed 1 GB private image storage at $0.10/GB-month | $0.10 |
| Small versioned S3 state storage and light requests | about $0.01–$0.10 |
| **Baseline total** | **about $13/month** |

A rough **$13–$16/month** budget allows small additional query/request variation,
but excludes taxes, support, burst CPU-credit charges, significant internet egress,
backups, load balancers, NAT gateways, and managed services. Free Tier/credits and
commitment discounts are deliberately not assumed. Retained image versions, S3
state versions, and higher log volume increase costs. A 1 GiB t3.micro is for this
small app target, not enough for the full monitoring stack; production sizing,
redundancy, TLS ingress, and durable observability would raise this estimate.
Verify account/region prices and expected traffic in the AWS calculator before
provisioning.

Sources: [EC2 T3 rates](https://aws.amazon.com/ec2/instance-types/t3/),
[public IPv4 pricing](https://aws.amazon.com/vpc/pricing/),
[gp3 storage pricing](https://aws.amazon.com/ebs/general-purpose/),
[CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/),
[ECR pricing](https://aws.amazon.com/ecr/pricing/),
[S3 pricing](https://aws.amazon.com/s3/pricing/), and
[AWS Pricing Calculator](https://calculator.aws/).

## What I Would Improve with More Time

- Run an authorized AWS plan/apply, confirm bootstrap/SSM/CloudWatch end to end,
  retain real deployment/rollback evidence, then destroy the assessment resources.
  Current AWS evidence remains validation and mocked plans, not a successful apply.
- Add TLS, multi-AZ capacity/load balancing, and blue/green or canary promotion so
  EC2 releases can preserve availability; benchmark before choosing ECS or EKS.
- Scan both release architectures and every monitoring image on a schedule,
  maintain dependency updates, pin actions by commit, and sign/verify image
  provenance. Keep development tools out of the runtime using dependency groups
  without duplicating version declarations.
- Add Alertmanager with a tested receiver, application service objectives, and
  route/status-specific alert tuning. Keep long-term metrics/logs in durable
  managed/object storage and test restore procedures and retention under load.
- Replace direct Docker socket access with an API-filtering proxy, reduce cAdvisor
  privileges per platform, and use external secret management/rotation for future
  application credentials.
- Test higher traffic, graceful shutdown with in-flight long requests, node loss,
  disk-full behavior, and host-script behavior on remote/stale mounts. Add bounded
  fleet-level collection deadlines and centralized health-log shipping when the
  one-host script becomes a fleet tool.

## AI Assistance

OpenAI Codex assisted with implementation, troubleshooting, tests, and documentation.
The result was checked with automated tests, lint/configuration validators, live
Docker metrics/log queries, and the recorded kind rollout/rollback. Screenshots
show the running local dashboards. No successful AWS apply or deployment is
claimed without an authorized AWS run. AI assistance does not replace the
submitter's review and ability to explain the code and trade-offs.
