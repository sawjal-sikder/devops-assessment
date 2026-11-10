# GitHub Actions CI/CD setup

## What runs

Every pull request runs `.github/workflows/ci.yml` with read-only repository
permissions and no AWS credentials. It runs Ruff lint/format checks, pytest with
an 85% application coverage gate, Hadolint, ShellCheck, an image build, and Trivy.
Trivy fails the job for CRITICAL vulnerabilities, including those without a fix;
scanner errors also fail the job. Coverage XML/HTML and scanner reports are saved
as workflow artifacts. Coverage is also shown in the job summary. Configure branch
protection on `main` to require all three CI jobs and PR review before merging.
Do not replace `pull_request` with `pull_request_target` for untrusted PR code.

Every push to `main` runs the same checks before publishing or deploying. The
release job builds `linux/amd64` and `linux/arm64` using QEMU/Buildx, with GitHub
Actions layer caching, and pushes to private Amazon ECR. `VERSION` holds the base
semantic version; change it as part of a normal reviewed PR. For base `1.0.0`,
run 42, attempt 1, tags are:

- `sha-<full git commit SHA>`
- `1.0.0-build.42.1` (a valid, unique semantic prerelease version)

No `latest` tag is required. The application and OCI version label receive the
semantic version. Deployment uses the returned multi-architecture manifest digest
so the host selects its architecture without a tag changing underneath it.
The SHA tag is updated on reruns, so configure this repository with mutable tags
(or an ECR immutability exclusion for `sha-*`); semantic tags remain unique.
The PR/main CI image scan covers amd64; publishing also builds arm64, but does
not claim separate vulnerability scan coverage of the arm64 result.

## GitHub variables and secrets

Create an environment named **production** at **Settings → Environments**. Limit
its deployment branches to `main`; optionally add required reviewers according
to your release policy. Under that environment's variables, configure:

| Variable | Example / purpose |
| --- | --- |
| `AWS_REGION` | Your AWS region, e.g. `us-east-1` |
| `AWS_ROLE_ARN` | ARN of the GitHub OIDC deployment role |
| `ECR_REPOSITORY` | Existing ECR repository name, e.g. `devops-task` (without registry hostname) |
| `EC2_INSTANCE_ID` | Existing, SSM-managed Step 3 instance ID |

**Required GitHub secrets: none.** OIDC supplies temporary AWS credentials.
Do not add AWS access keys, SSH keys, registry passwords, or credentials to `.env`
or workflow YAML. The EC2 instance profile supplies its own temporary ECR pull
credentials; the registry login uses stdin and an ephemeral Docker config that is
removed after deployment. The service currently needs no application secrets.

## AWS prerequisites

The Terraform files in this repository are currently placeholders. These workflows
consume an existing Step 3 EC2 instance; they do not provision it or create ECR/IAM.
Before pushing to main, create/configure:

1. An ECR repository in `AWS_REGION`, reachable by the instance.
2. GitHub's IAM OIDC provider, URL `https://token.actions.githubusercontent.com`,
   audience `sts.amazonaws.com`.
3. A deployment role with the trust policy below and permissions scoped as below.
4. An EC2 instance with the SSM agent running and registered, Docker Engine, AWS
   CLI v2, Bash, curl, base64, and flock (util-linux). Docker must be running. SSM
   runs the command as root. Use an instance profile with
   `AmazonSSMManagedInstanceCore` and the ECR pull policy below.
5. Outbound HTTPS access to SSM, ECR API/Docker endpoints, and S3 image layers,
   either through internet/NAT or the relevant VPC endpoints. No SSH ingress is
   needed. Allow inbound 8080 only from intended clients/load balancer; the smoke
   test runs on the instance against loopback.

Replace `<ACCOUNT_ID>`, `<REGION>`, `<REPOSITORY>`, and `<INSTANCE_ID>` in the example
policies with your values. They are placeholders, not credentials.

OIDC role trust policy for this repository and the production environment:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:sawjal-sikder/devops-engineer-task:environment:production"
    }}
  }]
}
```

The environment subject relies on GitHub's environment branch restriction to
limit deployment to `main`. Adjust the subject if the repository is renamed.

GitHub deployment role permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
    {"Effect": "Allow", "Action": [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage"
    ], "Resource": "arn:aws:ecr:<REGION>:<ACCOUNT_ID>:repository/<REPOSITORY>"},
    {"Effect": "Allow", "Action": "ssm:SendCommand", "Resource": [
      "arn:aws:ssm:<REGION>::document/AWS-RunShellScript",
      "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/<INSTANCE_ID>"
    ]},
    {"Effect": "Allow", "Action": "ssm:GetCommandInvocation", "Resource": "*"}
  ]
}
```

In addition to `AmazonSSMManagedInstanceCore`, the EC2 role needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
    {"Effect": "Allow", "Action": [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"
    ], "Resource": "arn:aws:ecr:<REGION>:<ACCOUNT_ID>:repository/<REPOSITORY>"}
  ]
}
```

## Deployment and rollback behavior

The workflow sends the checked-out deployment scripts through SSM; the instance
does not need Git or repository access. The script locks deployments on the host,
pulls the new digest before disturbing the running service, retains the current
container as `devops-task-previous`, and starts `devops-task` on port 8080 with
resource limits and the image's health check. It polls `/health` for up to 30
attempts (two seconds between attempts; each HTTP timeout is three seconds).
A successful HTTP response is the smoke-test gate. Expect a short service
interruption while the containers switch on this single instance.

On container startup or smoke-test failure, an EXIT trap removes the failed
container, renames and restarts the retained container with its exact previous
image and configuration, and checks `/health` again. The job remains failed even
if rollback succeeds. A first deployment has no previous image: failure removes
the failed container and reports that operator action is needed. Image pull
failure leaves the running container untouched. One previous container remains
stopped after success for recovery; avoid pruning images/containers during a
release. No persistent application data is stored in these containers.

Main deployments are serialized and not cancelled by newer pushes. A host flock
also prevents overlapping manual/remote deployments. SSM has a 540-second remote
execution timeout. If the runner is interrupted or times out, inspect the SSM
command before retrying: the remote command may still be running. Host failure,
forced termination, or loss of Docker/SSM cannot be repaired by a shell trap.

## Evidence and validation

After a real deployment, retain the GitHub Actions run URL and download the
`deployment-evidence-<run-id>-<attempt>` artifact. It contains the SSM command
status, stdout (including successful smoke test or rollback), and stderr. The job
summary also records the command ID, deployed digest, and result. Evidence is
retained for 90 days; download it before destroying AWS resources or before
retention expires. SSM output has service size limits, so use SSM/CloudWatch for
longer operational logs if needed.

No successful AWS deploy is claimed by this repository's local validation. An
actual run requires the variables and AWS resources above. Local deployment tests
simulate Docker and HTTP to verify successful promotion, failed image pull,
failed startup, failed smoke test with rollback, and first-deployment failure.
The real application subprocess test verifies SIGTERM cleanup separately.

References: [Docker Actions cache](https://docs.docker.com/build/cache/backends/gha/),
[AWS CLI SSM commands](https://docs.aws.amazon.com/systems-manager/latest/userguide/walkthrough-cli.html),
and [Trivy action scan options](https://github.com/aquasecurity/trivy-action).
