# Terraform: staging and production on AWS

This configuration creates one public-subnet EC2 instance in a dedicated VPC,
Internet Gateway and route table, encrypted root volume, security group, scoped
instance role/profile, and a CloudWatch Logs group with retention. Only TCP 8080
is exposed to explicitly approved client CIDRs. There is no SSH key or port 22.
Outbound TCP 443 allows package downloads, ECR, SSM, and CloudWatch; VPC-provided
DNS is used. The example is a single-instance assessment target, with no HA or TLS.

The Amazon Linux 2023 AMI comes from AWS's public SSM parameter. User data installs
Docker, enables SSM, sets the Docker `awslogs` driver, then starts the specified
ECR digest through a retrying bootstrap systemd unit. Docker restarts the app on
host reboot. A marker prevents bootstrap from replacing a later CI deployment
with the original image. Instance-profile temporary credentials supply ECR and
CloudWatch access; IMDSv2 is mandatory and containers cannot reach IMDS through the
one-hop metadata response limit. The instance role permits ECR auth (AWS requires
`Resource: *` for that action), pull actions for only the chosen repository, log
stream creation/events for only the app log group, and SSM registration/channels.
It cannot push images, create log groups, read app secrets, or administer AWS.
The logging driver uses a bounded, nonblocking 4 MB buffer; prolonged CloudWatch
outages can drop logs after that buffer fills.

The existing deployment script recognizes the daemon's `awslogs` driver, preserving
CloudWatch collection after CI releases. Without it, json-file rotation flags
would be invalid for the CloudWatch driver. Inspect startup using SSM and
`sudo journalctl -u devops-bootstrap.service` or `/var/log/cloud-init-output.log`.
Terraform apply completion does not imply cloud-init/application readiness.

## Prerequisites and credentials

Use Terraform >= 1.10, AWS CLI v2, Docker/Buildx, and an AWS account with authorized
provisioning access. Use an IAM Identity Center/SSO profile locally:

```sh
aws configure sso --profile devops-task
aws sso login --profile devops-task
export AWS_PROFILE=devops-task
export AWS_REGION=us-east-1
aws sts get-caller-identity
```

The provisioning identity needs EC2/VPC, IAM role/profile creation and `iam:PassRole`,
CloudWatch Logs provisioning, ECR describe access, and read access to AWS's public
AMI SSM parameter. Bootstrap additionally needs S3 bucket management. Scope these
to the project's names/account, and use your organization's provisioning role.
The GitHub role remains a separate OIDC identity for releases, not an instance role
or an administrative Terraform identity. No access keys belong in tfvars/backend
files. State and saved plans can contain configuration; treat them as sensitive.

An ECR repository and a published image must exist before the application root
can plan/apply. This avoids granting EC2 permission to publish images. If starting
from scratch, authenticate with SSO and publish an initial image first:

```sh
aws ecr create-repository --repository-name devops-task
registry=$(aws ecr describe-repositories --repository-names devops-task --query 'repositories[0].repositoryUri' --output text)
aws ecr get-login-password | docker login --username AWS --password-stdin "${registry%%/*}"
docker buildx build --platform linux/amd64,linux/arm64 --push -t "$registry:1.0.0" .
aws ecr describe-images --repository-name devops-task --image-ids imageTag=1.0.0 --query 'imageDetails[0].imageDigest' --output text
```

Use the repository URL plus `@sha256:...` in your tfvars. The example account,
digest, and documentation CIDR are placeholders and must be replaced. The default
`t3.micro` uses an x86_64 AMI; use a compatible x86 instance type. Verify current
Free Tier eligibility in your account. EC2, EBS, public IPv4, S3, and CloudWatch
can incur charges; no cost-free apply is promised.

## One-time S3 state bootstrap

The separate `terraform/bootstrap` root creates a private, versioned, encrypted,
TLS-only state bucket. Pick a globally unique name:

```sh
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap plan -var='bucket_name=YOUR-UNIQUE-STATE-BUCKET' -out=bootstrap.tfplan
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

This initial root uses local state to break the bucket/backend creation dependency;
keep its ignored `terraform.tfstate` securely until final bucket cleanup. The
application's state is always remote. In a team, manage the state bucket in your
organization's separately secured bootstrap/state system.

## Plan and apply staging

```sh
cp terraform/environments/staging.example.tfvars terraform/environments/staging.tfvars
cp terraform/environments/staging.s3.tfbackend.example terraform/environments/staging.tfbackend
# Edit the two copies: real image digest, your client IPv4 /32, bucket and region.
terraform -chdir=terraform init -reconfigure -backend-config=environments/staging.tfbackend
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform plan -var-file=environments/staging.tfvars -out=staging.tfplan
terraform -chdir=terraform apply staging.tfplan
terraform -chdir=terraform output
```

Capture actual plan/apply output using `tee` with `set -o pipefail` in Bash, or
retain screenshots and the GitHub/terminal run details. Check the instance after
bootstrap finishes:

```sh
instance=$(terraform -chdir=terraform output -raw instance_id)
aws ssm start-session --target "$instance"
# In the instance session:
sudo systemctl status devops-bootstrap.service
sudo docker inspect devops-task --format '{{.State.Health.Status}}'
curl --fail http://127.0.0.1:8080/health
sudo docker info --format '{{.LoggingDriver}}'
# Exit the session, then inspect the environment's log group:
aws logs tail /devops-task/staging/app --since 10m
```

Use the `health_url` output from your approved network to test inbound access.
SSM registration and IAM propagation may take a few minutes. Modern SSM Agent
uses `ssmmessages`; the role intentionally omits legacy ec2messages and unrelated
inventory/patching/parameter-read permissions.

## Production and state isolation

Copy/edit the production example files and repeat with the production file names.
Use a different S3 key for each environment. Terraform cannot interpolate variables
in backend blocks; the `.tfbackend` files set keys explicitly. When switching
between existing environments, use `init -reconfigure`, **not** `-migrate-state`.
Separate checkout directories (or `TF_DATA_DIR` values) avoid backend cache mixups.
Run only one environment operation in a working directory at a time.

S3 uses native lock files with `use_lockfile=true`; DynamoDB is unnecessary.
Backend credentials come from the AWS identity chain. The backend identity needs
`s3:ListBucket` on the state bucket, `s3:GetObject`/`s3:PutObject` on its environment
state object, and `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on the corresponding
`.tflock` object. Scope object access to that environment's key. State versioning
allows recovery; do not use `-lock=false` to bypass a competing operation.
See [HashiCorp's S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3).

Changing `image` or user data through Terraform replaces EC2 (and can change its
public IP). Use the existing CI SSM workflow for ordinary container-only releases;
coordinate later Terraform image changes rather than applying an obsolete digest.

## CI integration

In GitHub's `production` environment configure variables `AWS_REGION`,
`AWS_ROLE_ARN`, `ECR_REPOSITORY`, and `EC2_INSTANCE_ID` (from Terraform's output).
Restrict the environment to the `main` branch. The environment remains named
`production`; the branch trigger is `main`. The OIDC role trust must
allow audience `sts.amazonaws.com` and subject
`repo:sawjal-sikder/devops-assessment:environment:production` (the canonical repository is `sawjal-sikder/devops-assessment`; adjust if renamed).
Give that role ECR push actions scoped to this repository, ECR token acquisition,
`ssm:SendCommand` scoped to this instance and the AWS-RunShellScript document, and
`ssm:GetCommandInvocation` for results. The EC2 role is already supplied by this
Terraform root. No GitHub secret or SSH key is needed. Pull-request CI uses no AWS.

## Destroy after testing

Destroy each application environment before touching the shared state bucket:

```sh
terraform -chdir=terraform init -reconfigure -backend-config=environments/staging.tfbackend
terraform -chdir=terraform plan -destroy -var-file=environments/staging.tfvars -out=destroy-staging.tfplan
terraform -chdir=terraform apply destroy-staging.tfplan
# Repeat for production using its own backend and tfvars, if it was applied.
```

This removes EC2, its root volume, network resources, instance IAM resources, and
the log group. Save evidence before destroying: CloudWatch logs are deleted with
the group. The ECR repository is external to this root; delete it only if created
for this assessment and no longer needed (`aws ecr delete-repository
--repository-name devops-task --force`).

The bootstrap bucket deliberately has `force_destroy=false`. After all deployments
are destroyed and evidence/state backups are retained, explicitly empty all object
versions and delete markers from this assessment-only bucket via S3, then destroy
the bootstrap root with the same `bucket_name` and region:

```sh
terraform -chdir=terraform/bootstrap destroy -var='bucket_name=YOUR-UNIQUE-STATE-BUCKET'
```

Emptying a versioned
bucket deletes its recovery history; never do this to a shared active state bucket.

## Validation evidence and limitations

`docs/evidence/terraform-test.txt` contains an actual `terraform test` run using a
mock AWS provider: staging/production plans and invalid-input checks. Both roots
also pass `terraform validate`. Mocks do not contact AWS and do not verify live IAM,
AMI availability, bootstrapping, SSM registration, or CloudWatch delivery. The IAM
policy-document data sources are mocked as JSON, so tests do not prove live policy
behavior. On 2026-11-11 an authorized AWS run produced a real
[13-resource plan](evidence/terraform-plan.txt),
[successful apply](evidence/terraform-apply.txt), and
[post-apply no-change plan](evidence/terraform-plan-no-changes.txt). The new EC2
instance registered with SSM; [bootstrap and health checks](evidence/aws-bootstrap-smoke.json)
succeeded. A [manual SSM deployment](evidence/aws-ssm-deploy.json) of version 1.0.1
through `scripts/ssm_payload.py`/`deploy.sh` succeeded, retaining version 1.0.0 for
recovery. [CloudWatch log events](evidence/aws-cloudwatch-logs.json) confirm the
instance role and Docker logging integration worked.

The run created a separate temporary `devops-task-assessment` ECR repository and
unique state bucket. The staging deployment was destroyed immediately after
capturing evidence; [the evidence index](evidence/README.md) records the final
cleanup results. Saved evidence contains resource IDs and public endpoints, not
AWS access keys, registry tokens, or Terraform state/plan binaries.

GitHub Actions execution is a separate remaining requirement: the successful
manual SSM command must not be presented as a successful GitHub workflow run.
After committing these fixes to `main`, configure GitHub's production environment
for that branch, run the release with a valid OIDC role/instance, and retain its
successful run URL and deployment artifact. The temporary instance from this
validation is not intended to remain a deploy target after cleanup.

CloudWatch integration follows Docker's
[awslogs driver documentation](https://docs.docker.com/engine/logging/drivers/awslogs/).
