# Getting Started

This guide walks through deploying the FinOps framework into a fresh AWS account from a Terraform Enterprise workspace.

## Prerequisites

1. **AWS account** in which the framework will be deployed. This is typically a dedicated `finops-shared` account in a banking landing zone, but can be any account if you're starting smaller.
2. **Terraform Enterprise workspace** with one of the following AWS credential approaches:
   - **Dynamic credentials** (recommended): TFE workspace assumes a role in the target AWS account via OIDC. See HashiCorp docs for Dynamic Credentials.
   - **Static credentials**: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` set as sensitive environment variables in the workspace.
3. **IAM permissions** for the TFE workspace credentials — see below.
4. **AWS Cost Explorer enabled** in the target account (one-time click in the console).
5. **AWS Config enabled** (the framework will enable it via the `tag-governance` module if `enable_config_recorder = true`, but if Config is already deployed by your security/governance team, set this to `false`).

## Required IAM permissions for the TFE workspace

The TFE workspace's AWS credentials need permissions to manage the resources the framework creates. A pragmatic starting point: attach the AWS-managed `AdministratorAccess` policy for the initial bootstrap, then narrow it down once the framework is stable. For a least-privilege policy, you'll need (at minimum) actions on:

- `kms:*` (for the FinOps CMK)
- `s3:*` (for CUR, FOCUS, Athena results, Config buckets)
- `cur:*`, `bcm-data-exports:*` (for CUR 2.0 and FOCUS exports)
- `budgets:*`, `ce:*` (Budgets and Cost Explorer / Anomaly Detection / Cost Categories)
- `athena:*`, `glue:*` (Athena workgroup and CUR catalog)
- `sns:*` (alerting topic)
- `lambda:*`, `iam:*` (function deployment and roles)
- `events:*` (EventBridge schedules)
- `config:*` (AWS Config recorder and rules)
- `compute-optimizer:*`, `cost-optimization-hub:*` (enrollment)

## First deployment — step by step

### 1. Clone the repo into your TFE workspace VCS

Push the framework to your git provider and connect a new TFE workspace to it. Set the working directory to the repo root (where `main.tf` lives).

### 2. Configure the workspace

In TFE → Workspace → Variables, add the following:

**Terraform variables:**

| Name | Sensitive | Example |
|---|---|---|
| `namespace` | no | `examplebank` |
| `environment` | no | `shared` |
| `stack_name` | no | `finops` |
| `aws_region` | no | `eu-central-1` |
| `budget_currency` | no | `USD` |
| `budgets` | no | `{ account_monthly = { scope = "account", amount = 250000 } }` (HCL) |
| `notification_emails` | no | `["finops@examplebank.com"]` (HCL) |

**Environment variables:**

| Name | Sensitive | Notes |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | yes | If using static creds |
| `AWS_SECRET_ACCESS_KEY` | yes | If using static creds |
| `AWS_DEFAULT_REGION` | no | `eu-central-1` |
| `TFC_AWS_PROVIDER_AUTH` | no | `true` if using dynamic credentials |
| `TFC_AWS_RUN_ROLE_ARN` | no | Role ARN if using dynamic credentials |

**Sensitive Terraform variables:**

| Name | Notes |
|---|---|
| `slack_webhook_url` | Optional. If absent, Slack notifier is not deployed. |
| `teams_webhook_url` | Optional. If absent, Teams notifier is not deployed. |

### 3. Initial plan

Queue a plan. Expect ~80–120 resources on first apply depending on which modules you enable. Review:

- **KMS key creation** — check the key policy.
- **S3 buckets** — note bucket names (these include the account ID).
- **CUR report** — note that it's created via the `us-east-1` provider alias. Data starts landing within ~24 hours.
- **IAM roles and policies** — verify each Lambda role is scoped narrowly.

### 4. First apply

Apply the plan. Monitor for:

- **CUR S3 bucket policy errors** — if the bucket policy is rejected, it's usually because the bucket name collides with one already deleted in the last 24 hours. Change `cur_s3_bucket_name`.
- **Compute Optimizer / Cost Optimization Hub enrollment** — these take a few minutes and may show as "in progress" briefly.

### 5. Post-apply validation

After the apply succeeds:

1. **Confirm email subscriptions.** Each `notification_emails` entry receives an SNS confirmation email. Click through to confirm.
2. **Wait 24 hours for first CUR delivery.** Check the S3 bucket — you should see `cur2/<report-name>/` populating with `.parquet` files.
3. **Run a test Athena query.** In the Athena console, switch to the workgroup created by the framework, select the database, and run:
   ```sql
   SELECT COUNT(*) FROM <database_name>.<table_name>;
   ```
   (The table name is created by the CUR crawler automatically once data lands.)
4. **Trigger the idle cleanup Lambda manually** (dry-run mode is on by default — no risk).
5. **Verify Slack/Teams delivery** by publishing a test message to the SNS topic.

## Common first-time issues

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied` on CUR report creation | Provider not using `us-east-1` alias | Confirm `providers.tf` is unchanged |
| Athena queries return zero rows | CUR data hasn't landed yet (first delivery takes up to 24h) | Wait |
| `aws_config_configuration_recorder` errors | Config already enabled in account | Set `enable_config_recorder = false` |
| Email subscriptions stuck in "Pending" | User didn't click confirmation link | Resend confirmation or update var |
| Lambda fails with `kms:Decrypt` denied | Lambda role policy missing key | Should not happen; raise an issue |

## Moving from minimal to full

Recommended progression:

1. **Week 1–2**: Deploy with `enable_idle_cleanup = false`, `enable_instance_scheduler = false`. Just collect data and validate CUR.
2. **Week 3–4**: Enable `enable_idle_cleanup = true` with `idle_cleanup_dry_run = true`. Review the SNS reports, confirm no false positives.
3. **Month 2**: Add `enable_instance_scheduler = true`, but no schedules attached yet to instances. Tag a few dev instances with `Schedule = office-hours-cet` and observe.
4. **Month 3**: Once confidence is high, you may flip `idle_cleanup_dry_run = false` — but most banks **keep dry-run on permanently** and use a human-in-the-loop ticketing workflow off the SNS topic instead.
