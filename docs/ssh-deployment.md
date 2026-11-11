# EC2 SSH deployment

The active `.github/workflows/deploy.yml` runs CI, publishes the root Dockerfile
for amd64/arm64 to GHCR, and deploys its exact digest through SSH. Pushes to `main`
and `v*` tags trigger deployment. The service is FastAPI (`app`), not Django.

## Repository secrets

Set these in Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| SERVER_HOST | ec2-3-25-75-233.ap-southeast-2.compute.amazonaws.com |
| SERVER_USER | ubuntu |
| SERVER_PATH | Optional override; defaults to `/home/ubuntu/devops-assessment` |
| SSH_PRIVATE_KEY | Full private key contents authorized for ubuntu, including BEGIN/END lines |
| SERVER_FINGERPRINT | SHA256 SSH host fingerprint verified through a trusted server session |
| SERVER_PORT | Optional; defaults to 22 |

From your trusted SSH session, obtain the fingerprint:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Copy only the `SHA256:...` field. The EC2 repository deploy key is separate from
the key Actions uses to connect to EC2. Git fetch uses the server's deploy key.
The temporary GITHUB_TOKEN authenticates image pulls; the repository must have
access to the GHCR package. No stored AWS credentials or OIDC role is used.

## Server preparation

Install Docker Engine, Docker Compose v2 with `--wait` support, Git, and `flock`.
The SSH user must own the checkout and be able to run Docker without sudo.
Verify from the actual checkout:

```sh
docker info
docker compose version
git fetch origin --tags
```

Keep the checkout clean. The workflow checks out the deployed commit in detached
HEAD mode, so do not use it for server-side development. No clone step is needed.
Configure any server-specific `.env` outside Git. A different existing service
bound to port 8080 must be stopped before this Compose deployment can use it.

Allow inbound SSH from the runner network in the EC2 security group. A rule
allowing only your personal IP does not allow GitHub-hosted runners. Use a runner
with controlled egress or a private-network runner if you require a fixed source.
Allow app port 8080 only to intended clients; add HTTPS ingress for public use.

Without an Elastic IP, stopping and starting EC2 can change its public IP and DNS.
Update SERVER_HOST afterward, or attach an Elastic IP and update SERVER_HOST once.

## Release and verification

Push the workflow and Compose change to `main`, then inspect GitHub Actions.
Alternatively, push a fresh release tag after committing the changes:

```sh
git tag v1.0.1
git push origin v1.0.1
```

On EC2, verify:

```sh
curl --fail http://127.0.0.1:8080/health
docker compose ps app
docker compose logs --tail 100 app
```

Compose uses DOCKER_IMAGE supplied by the workflow and waits for the existing app
healthcheck. Deployment may briefly interrupt traffic. Failure marks the workflow
failed; this SSH/Compose path does not implement automatic rollback. Temporary
registry credentials are removed when the remote shell exits. Images are retained
for operator recovery. For manual Compose updates, explicitly export DOCKER_IMAGE
to a known-good GHCR digest first; the variable is not persisted in `.env`.

The Terraform/SSM scripts remain available as a separate deployment alternative;
do not run both deployment mechanisms against the same app port.
