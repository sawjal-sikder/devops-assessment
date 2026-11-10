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
pip install -r requirements-dev.txt
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
3.14.4 / Alpine 3.23 by version and SHA-256 digest. Development dependencies and
repository files are excluded from the build context by an allowlist `.dockerignore`.
The image runs as UID/GID `10001:10001`, has OCI metadata, a Python standard-library
health probe, and an exec-form entrypoint so SIGTERM reaches Uvicorn directly.

**Measured final image size: 118,100,605 bytes (118.1 MB / 112.63 MiB), linux/amd64.**
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
Pushes to `main` pass those checks, publish amd64/arm64 images to ECR with commit
SHA and semantic version tags, and deploy via GitHub OIDC and SSM with health-based
rollback. See [CI/CD setup](docs/cicd.md) for required GitHub variables, IAM policies,
EC2 prerequisites, tagging, rollback behavior, and deployment evidence. No GitHub
secrets or long-lived AWS access keys are required.
