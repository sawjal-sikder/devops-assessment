# Evidence index

AWS validation date: **2026-11-11**. This index distinguishes real AWS execution
from offline tests and from the GitHub Actions run still required for completion.

| Deliverable | Evidence | Result |
| --- | --- | --- |
| Root release version | [`../../VERSION`](../../VERSION) | `1.0.0`; CI validates it |
| Deploy on push to main | [`../../.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml) | Trigger and job guard both use `main`; GitHub environment remains `production` |
| Real initial Terraform plan | [terraform-plan.txt](terraform-plan.txt) | 13 to add, 0 to change, 0 to destroy |
| Real Terraform apply | [terraform-apply.txt](terraform-apply.txt) | 13 added successfully |
| Clean post-apply Terraform plan | [terraform-plan-no-changes.txt](terraform-plan-no-changes.txt) | No changes; infrastructure matches configuration |
| EC2 bootstrap and health | [aws-bootstrap-smoke.json](aws-bootstrap-smoke.json) | SSM Success; bootstrap active/exited successfully; `/health` healthy; `awslogs` enabled |
| Real new-version deployment | [aws-ssm-deploy.json](aws-ssm-deploy.json) | **Manual SSM command**, using repository deployment scripts; version 1.0.1 healthy; previous 1.0.0 image retained |
| CloudWatch delivery | [aws-cloudwatch-logs.json](aws-cloudwatch-logs.json) | Structured application events from the new deployment |
| Application cleanup | [terraform-destroy.txt](terraform-destroy.txt) | 13 destroyed |
| State backend bootstrap/apply | [terraform-bootstrap-plan.txt](terraform-bootstrap-plan.txt), [terraform-bootstrap-apply.txt](terraform-bootstrap-apply.txt) | Separate private/versioned/encrypted S3 bucket: 5 added |
| Backend cleanup | [terraform-bootstrap-destroy.txt](terraform-bootstrap-destroy.txt) | 5 destroyed; versioned state objects removed first |
| AWS cleanup inventory | [aws-cleanup.json](aws-cleanup.json) | EC2 terminated; test VPC, ECR repository, S3 bucket, and log group removed |
| Successful GitHub Actions deployment | **Pending** | No successful run URL/artifact is supplied; do not treat the manual SSM result as GitHub Actions evidence |

The saved SSM JSON is the real `get-command-invocation` response, with command ID,
execution timing, stdout/stderr, and terminal status. Brief initial connection
resets occurred while the app started; the terminal command status and final
health/version checks succeeded. Resource IDs, image digests, and historical public
endpoints are not credentials. Saved Terraform plan *text* is included; binary
plans, state, backend settings, and temporary registry credentials are not committed.

## Remaining GitHub Actions evidence

1. Commit all fixes, including the new root `VERSION`, and use `main` as the release
   branch. Main pushes run the reusable CI before publishing/deploying.
2. In the GitHub **production environment**, allow deployments from `main`, not a
   branch named `production`. Protect `main` with PR/check requirements.
3. Recreate an authorized AWS deployment target before running the workflow: this
   validation target and temporary ECR/state resources are intentionally destroyed
   after testing. Configure `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY`, and the
   new `EC2_INSTANCE_ID` in that environment. Follow [the AWS setup](../terraform.md).
4. Match the OIDC trust subject to the canonical repository:
   `repo:sawjal-sikder/devops-assessment:environment:production`.
5. Push/merge the reviewed changes to `main` and retain the successful **Publish
   and deploy** run URL and `deployment-evidence-<run-id>-<attempt>` artifact. Download
   it before destroying the AWS resources again.
6. Add that real run URL/artifact to the submission. Current local workflow linting
   and manual SSM execution do not prove an authenticated GitHub Actions deployment.

AWS access was available during this validation, but no GitHub API token/CLI
session was available to configure environment variables, request a workflow run,
or download authenticated deployment artifacts. Repository SSH read access was
verified. No changes were committed or pushed to the remote repository by the
validation process.

## Earlier local evidence

- [Kubernetes rollout and rollback](kubernetes-rollout.txt), [metrics/HPA](kubernetes-status.txt), and [kind cleanup](kubernetes-cleanup.txt).
- [Monitoring end-to-end checks](monitoring.txt) and screenshots under `../screenshots/`.
- [Python/health-script test results](test-results.txt).
- [Terraform validation](terraform-validate.txt) and [mocked plan tests](terraform-test.txt); these are supplemental, not replacements for the real AWS logs above.
