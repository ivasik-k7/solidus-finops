# Terraform Enterprise Setup

## Workspace configuration

Create a TFE workspace with these properties:

| Setting | Value |
|---|---|
| Workspace name | `finops-shared` (or per your naming convention) |
| Execution mode | Remote |
| Apply method | Manual apply (recommended for first month, then auto if confident) |
| Terraform version | 1.6 or later |
| VCS provider | Whichever your bank uses (GitHub Enterprise, GitLab, Bitbucket) |
| Working directory | Repo root (where `main.tf` lives), or `examples/production` |
| Auto-apply | Off initially, on once stable |
| Run triggers | None |

## Credential strategy

Two viable approaches:

### Option A — Dynamic credentials (recommended)

If your TFE is on Terraform Cloud or has the dynamic credentials feature, use OIDC trust between TFE and AWS. This eliminates static keys entirely.

Set workspace environment variables:

| Variable | Value | Sensitive |
|---|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` | no |
| `TFC_AWS_RUN_ROLE_ARN` | `arn:aws:iam::<account-id>:role/tfe-finops` | no |
| `AWS_DEFAULT_REGION` | `eu-central-1` | no |

In AWS, create the role `tfe-finops` with a trust policy that accepts TFE's OIDC token, scoped to this specific workspace.

### Option B — Static credentials

Less ideal, but works. Create an IAM user `tfe-finops`, attach the permissions from `GETTING_STARTED.md`, generate keys, store in TFE:

| Variable | Sensitive |
|---|---|
| `AWS_ACCESS_KEY_ID` | yes |
| `AWS_SECRET_ACCESS_KEY` | yes |
| `AWS_DEFAULT_REGION` | no |

Rotate keys at least quarterly. Banks under PCI DSS must rotate at least every 90 days.

## Required Terraform variables

These should be set in the workspace's Terraform variables section (not as environment variables):

| Variable | Required | Sensitive |
|---|---|---|
| `namespace` | yes | no |
| `environment` | no (defaults `shared`) | no |
| `stack_name` | no (defaults `finops`) | no |
| `aws_region` | no (defaults `eu-central-1`) | no |
| `budget_currency` | no (defaults `USD`) | no |
| `budgets` | yes (set to `{}` to disable) | no |
| `notification_emails` | yes | no |
| `slack_webhook_url` | no | yes |
| `teams_webhook_url` | no | yes |
| Plus any from `terraform.auto.tfvars.example` you want to override | | |

## Workspace permissions

Restrict workspace access to the FinOps team. The state file contains:

- KMS key ARNs and IDs (low risk by themselves)
- SNS topic ARNs and SQS DLQ ARNs
- Lambda function ARNs and IAM role ARNs
- Secrets Manager **ARNs** for webhook URLs (the values themselves stay in Secrets Manager, not state)
- **No secret material** — webhook URLs are sensitive Terraform variables (encrypted in TFE) and persist only inside Secrets Manager after apply.

Recommended team RBAC:

- **FinOps Engineers**: Plan + Apply
- **FinOps Analysts**: Plan + Read state (for outputs)
- **Internal Audit**: Read state only
- **Everyone else**: No access

## Run policies (Sentinel or OPA)

If your TFE has Sentinel or OPA enabled, recommended policies for this workspace:

1. **Deny destructive changes to the KMS key.** The framework sets `prevent_destroy = true` and a 30-day deletion window. A run that removes either should require explicit override.
2. **Deny `force_destroy = true` on the cost-data S3 bucket.** Combined with the existing `prevent_destroy`, this is double protection for the most important data the framework owns.
3. **Require approval for any change to `cost_categories`.** Chargeback logic changes are financially material.
4. **Limit changes to `notification_emails` to a specific approver group.** Prevents silent muting of alerts.
5. **Require approval for any change that disables a Lambda alarm.** The framework's audit assumption is that silent Lambda failures are impossible.

## Run notifications

Wire workspace notifications to:

- Slack channel `#finops-terraform` for all run events
- Email distribution for failed applies
- ServiceNow/Jira integration for any run requiring approval

## Disaster recovery

Workspace state is automatically backed up by TFE. To recover:

1. Restore the workspace from TFE backups (or recreate and import).
2. Re-run `terraform plan` — Terraform will reconcile state.
3. For the CUR S3 bucket, **data is preserved separately** — even if you destroy the framework, the bucket data remains until you also empty and delete the bucket. This is intentional.
