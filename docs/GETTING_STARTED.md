# Getting Started — Solidus FinOps

This guide walks through deploying Solidus FinOps into a fresh AWS account
from a Terraform Enterprise workspace.

## Prerequisites

1. **AWS account** in which the framework will be deployed. This is
   typically a dedicated `finops-shared` account in a landing zone, but can
   be any account if you're starting smaller.
2. **Terraform Enterprise workspace** with one of the following AWS
   credential approaches:
   - **Dynamic credentials** (recommended): TFE workspace assumes a role
     in the target AWS account via OIDC. See HashiCorp docs for Dynamic
     Credentials.
   - **Static credentials**: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
     set as sensitive environment variables in the workspace.
3. **IAM permissions** for the TFE workspace credentials — see below.
4. **AWS Cost Explorer enabled** in the target account (one-time click in
   the console). Required for `finops-metrics` to fetch commitment +
   anomaly + forecast data.
5. **AWS Config awareness.** If `tag_governance_enabled = true` and Config
   isn't already running at the org level (e.g. via Control Tower), the
   `tag-governance` module provisions its own recorder. If you already
   have org-managed Config, the module re-uses it.

## Required IAM permissions for the TFE workspace

The TFE workspace's AWS credentials need permissions to manage the
resources the framework creates. A pragmatic starting point: attach the
AWS-managed `AdministratorAccess` policy for the initial bootstrap, then
narrow it down once the framework is stable. For a least-privilege policy,
you'll need (at minimum) actions on:

- `kms:*` (the framework CMK)
- `s3:*` (cost-data + athena-results buckets, possibly Config delivery bucket)
- `bcm-data-exports:*`, `cur:*` (CUR 2.0 + FOCUS)
- `budgets:*`, `ce:*` (Budgets, Cost Explorer, Cost Anomaly Detection consumed by `finops-metrics`)
- `athena:*`, `glue:*` (Athena workgroup + named queries + Glue catalog)
- `sns:*` (events topic)
- `secretsmanager:*` (chat webhook secrets, if any channels declared inline)
- `lambda:*`, `iam:*` (Lambda deployment + roles)
- `events:*` (EventBridge schedules + rules)
- `config:*` (Config recorder + tag-governance rules, only if you let the framework manage Config)
- `dynamodb:*` (audit + state + KPI snapshot tables)
- `cloudwatch:*`, `logs:*` (metrics, alarms, dashboards, log groups)
- `sqs:*` (Lambda DLQs)

## First deployment — step by step

### 1. Clone the repo into your TFE workspace VCS

Push Solidus FinOps to your git provider and connect a new TFE workspace
to it. Set the working directory to the repo root (where `main.tf`
lives), or point at one of `examples/*` if you'd prefer a tighter starting
config.

### 2. Configure the workspace

In TFE → Workspace → Variables, add the following:

**Terraform variables:**

| Name | Sensitive | Example |
|---|---|---|
| `namespace` | no | `examplecorp` |
| `environment` | no | `shared` |
| `stack_name` | no | `finops` |
| `aws_primary_region` | no | `eu-central-1` |
| `aws_secondary_regions` | no | `["us-east-1", "ap-southeast-1"]` (HCL) |
| `budgets_currency` | no | `USD` |
| `budgets_items` | no | `{ account_monthly = { scope = "account", amount = 250000 } }` (HCL) |
| `alerting_legacy_emails` | no | `["finops@examplecorp.com"]` (HCL) |

**Environment variables:**

| Name | Sensitive | Notes |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | yes | If using static creds |
| `AWS_SECRET_ACCESS_KEY` | yes | If using static creds |
| `AWS_DEFAULT_REGION` | no | Must match `aws_primary_region` |
| `TFC_AWS_PROVIDER_AUTH` | no | `true` if using dynamic credentials |
| `TFC_AWS_RUN_ROLE_ARN` | no | Role ARN if using dynamic credentials |

**Sensitive Terraform variables:**

| Name | Notes |
|---|---|
| `alerting_slack_webhook_url` | Optional. If absent and `alerting_channels.slack` is empty, no Slack notifier is deployed. |
| `alerting_teams_webhook_url` | Optional. Same pattern for Teams. |

For multi-channel routing (PagerDuty / Opsgenie / multiple Slack channels
with per-channel severity filters / generic webhooks / SQS sinks), set
`alerting_channels` instead — see [modules/alerting/README.md](../modules/alerting/README.md).

### 3. Initial plan

Queue a plan. Expect ~100–150 resources on first apply depending on which
modules you enable. Review:

- **KMS key creation** — check the key policy.
- **S3 buckets** — note bucket names (these include the account ID).
- **CUR report** — note that it's created via the `us-east-1` provider
  alias. Data starts landing within ~24–48 hours.
- **IAM roles and policies** — verify each Lambda role is scoped narrowly
  (one role per Lambda, with conditional `sns:Publish` only when
  `events_topic_arn` is wired).
- **DynamoDB tables** — five audit tables (alerting events, budgets state,
  idle findings, scheduler state + GSI, KPI snapshots).

### 4. First apply

Apply the plan. Monitor for:

- **CUR S3 bucket policy errors** — if the bucket policy is rejected, it's
  usually because the bucket name collides with one already deleted in the
  last 24 hours. Change `cost_data_exports_bucket_name`.
- **Glue crawler initial run** — may take a few minutes to discover the
  first CUR partitions.

### 5. Post-apply validation

After the apply succeeds:

1. **Confirm email subscriptions.** Each `alerting_legacy_emails` entry
   receives an SNS confirmation email. Click through to confirm.
2. **Wait 24–48 hours for first CUR delivery.** Check the S3 bucket —
   you should see `cur2/<report-name>/` populating with `.parquet` files.
3. **Run a test Athena query.** In the Athena console, switch to the
   workgroup created by the framework, select the database, and run:
   ```sql
   SELECT COUNT(*) FROM "<database_name>"."<table_name>";
   ```
   The table name is discovered by the CUR crawler automatically once data
   lands. The framework provisions a pre-built named-queries library —
   visible under "Saved queries".
4. **Trigger the idle cleanup Lambda manually** (dry-run mode is on by
   default — no risk).
5. **Verify Slack/Teams delivery** by publishing a test message to the
   SNS topic.
6. **Check the dashboards.** `framework_status.dashboards` output lists
   them; one per module, all in `aws_primary_region`.

## Common first-time issues

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied` on CUR report creation | Provider not using `us-east-1` alias | Confirm `providers.tf` is unchanged |
| Athena queries return zero rows | CUR data hasn't landed yet (first delivery takes up to 48h) | Wait |
| `aws_config_configuration_recorder` errors | Config already enabled in the account | Set `tag_governance_record_global_resources = false` and rely on the existing recorder |
| Email subscriptions stuck in "Pending" | User didn't click confirmation link | Resend confirmation or update `alerting_legacy_emails` |
| Lambda fails with `kms:Decrypt` denied | Lambda role policy missing key | Should not happen; file an issue with the plan |
| `finops-metrics` aggregator first run returns nothing | No CUR partitions yet, or Cost Explorer not enabled | Wait 24–48h, then enable Cost Explorer in the AWS console |
| `terraform plan` shows dashboard drift | The `finops-metrics` aggregator re-PUTs its dashboard on every run | Expected; the resource has `ignore_changes = [dashboard_body]` so it's noise-free in plan |

## Moving from minimal to full

Recommended progression — also see [docs/PHASES.md](PHASES.md) for the
full Crawl / Walk / Run mapping:

1. **Week 1–2**: Deploy with `idle_cleanup_enabled = false`,
   `instance_scheduler_enabled = false`, `tag_governance_enabled = false`,
   `finops_metrics_enabled = false`. Just collect cost data and validate
   CUR.
2. **Week 3–4**: Enable `tag_governance_enabled = true` with a small
   required-tag set + `idle_cleanup_enabled = true` with
   `idle_cleanup_dry_run = true`. Review the SNS reports, confirm no false
   positives, place `FinOpsException=true` tags on legitimate "looks idle,
   actually isn't" resources.
3. **Month 2**: Add `finops_metrics_enabled = true`. The aggregator will
   begin emitting KPIs and writing DDB snapshots; trend metrics
   (`_7dAvg`, `_30dAvg`, `_WoWDriftPct`) accumulate over the next 30 days.
4. **Month 2**: Add `instance_scheduler_enabled = true`, but no schedules
   attached yet to instances. Tag a few dev instances with
   `Schedule=office-hours-cet` and observe one weekly cycle.
5. **Month 3**: Once confidence is high, you may flip
   `idle_cleanup_dry_run = false` — but many orgs **keep dry-run on
   permanently** and use a human-in-the-loop ticketing workflow off the
   SNS topic instead.
6. **Month 3+**: Add `finops_metrics_custom_kpis` for any org-specific
   unit-economics metrics (cost-per-transaction, cost-per-active-user,
   etc.).
