# examples/production

The **Run-phase** deployment — every available Solidus FinOps
capability is on, allocation is wired up, idle/scheduler automations
are active (still dry-run on first apply), multi-region scanning is
enabled, and Slack/Teams notifications route through the alerting
dispatcher.

Defaults lean conservative (7-year log retention, KMS CMK,
`prevent_destroy` on data resources) so the same code is valid for SOX
/ PCI / GDPR / DORA-regulated workloads. Trim `log_retention_days`
down to 365 for non-regulated accounts.

## What this example deploys

✅ All 7 modules

| Module | Configuration |
|---|---|
| **alerting** | Events bus + dispatcher Lambda. Slack + Teams webhooks via Secrets Manager. `alerting_legacy_emails` for finops + cloud-platform DLs. |
| **cost-data-exports** | CUR 2.0 + FOCUS 1.0; 7-year retention (`cost_data_exports_expiration_days = 2555`); Athena workgroup; named-queries library; daily health-check. |
| **tag-governance** | 6 mandatory tags (CostCenter / Environment / Application / Owner / BusinessUnit / DataClassification); Config rules; tag-drift detection on the 4 allocation tags; weekly untagged-cost report at `$5 000` alarm threshold; 4 allocation Resource Groups. |
| **budgets** | 7 budgets (account / 4 services / 2 BUs); daily performance Lambda; 85% adherence alarm threshold; 7-day burn-rate alarm. |
| **idle-resource-cleanup** | All 6 resource types ON (EBS / EIP / Snapshot / NAT / ENI / LB); **dry-run TRUE** on first apply. |
| **instance-scheduler** | Scheduler Lambda active; `max_actions_per_tick = 500`; weekly auto-discovery Lambda. |
| **finops-metrics** | Daily KPI aggregator; built-in + custom KPI surface; trend metrics (7d/30d/WoW); allocation alarm at 85%, commitment-coverage at 70%, forecast-drift at 10%. |

Multi-region scanning: `aws_secondary_regions = ["us-east-1"]` —
idle-cleanup and instance-scheduler iterate primary + secondary.

## Prerequisites

1. **AWS credentials** for an account with permissions to create KMS
   keys, IAM roles, SNS topics, Lambda functions, DynamoDB tables,
   S3 buckets, Glue databases, Athena workgroups, AWS Budgets, and
   AWS Config rules. Recommended approach: a dedicated `FinOpsAdmin`
   IAM role assumable from your CI/CD or `aws sso login`.

2. **Slack incoming webhook** for `#finops-info` and `#finops-alerts`
   (or your equivalent). Create via the Slack app config; the URL
   format is `https://hooks.slack.com/services/T.../B.../...`.

3. **Microsoft Teams incoming webhook** if you use Teams in addition
   to Slack. Optional — comment out the input below if Teams is
   unused.

4. **Account-level CloudTrail enabled** at the organization level —
   the framework relies on CloudTrail for the IAM + KMS audit trail,
   but does not provision it. AWS Control Tower satisfies this
   automatically.

## Run it

```bash
cd examples/production

# AWS credentials available (env / profile / instance role)
export AWS_PROFILE=examplebank-shared
export AWS_REGION=eu-central-1

# Copy the tfvars template and fill in the sensitive values.
# DO NOT commit terraform.tfvars to git — it carries webhook URLs.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan
terraform apply
```

Alternatively, set the sensitive values via env vars instead of a
tfvars file (recommended in TFE / Terraform Cloud workspaces):

```bash
export TF_VAR_slack_webhook_url="https://hooks.slack.com/services/..."
export TF_VAR_teams_webhook_url="https://yourorg.webhook.office.com/..."

terraform apply
```

In TFE / Terraform Cloud, declare both as **sensitive** workspace
variables.

Apply takes ~5–8 minutes (most of the time is AWS Config recorder + S3
bucket provisioning). Idle-cleanup runs once weekly on the configured
cron, so you won't see results for ~7 days. The KPI aggregator runs
daily at 07:00 UTC; the first run produces partial data until CUR has
its first full month.

## Verify it's working

```bash
# 1. All modules enabled?
terraform output -json enabled_modules | jq

# 2. Single-glance status including dashboard URLs
terraform output -json framework_status | jq

# 3. CUR pipeline alive
aws s3 ls "s3://$(terraform output -raw cost_data_exports_bucket_name)/cur2/" --recursive | tail

# 4. Slack channel got the "FinOps stack deployed" message
# (sent by the dispatcher Lambda on the first invocation)
```

## Day-2 operations

See [docs/OPERATIONAL_RUNBOOK.md](../../docs/OPERATIONAL_RUNBOOK.md)
for the canonical procedures: DLQ replay, snooze a finding, rotate a
webhook, force-run a Lambda, pause a module via reserved-concurrency,
quarterly health checks, Sev-1..4 escalation matrix.

For disasters (KMS deletion / DDB corruption / region outage), see
[docs/DISASTER_RECOVERY.md](../../docs/DISASTER_RECOVERY.md).

## Cost expectation

A typical production account (~10 000 resources, ~30 changes per
resource per month, AWS Config recorder ON):

| Component | Monthly |
|---|---|
| Framework baseline (KMS, Lambda, custom metrics, dashboards, alarms, DDB, Athena, etc.) | ~$40 |
| AWS Config (CI + rule evaluations) | ~$800 |
| AWS Config S3 storage | ~$1 |
| **Estimated total** | **~$840 / mo** |

If AWS Config is already enabled at the **organization level**
(typical with AWS Control Tower), set `enable_config_recorder = false`
inside the `tag-governance` module call; the framework re-uses the
org-managed recorder and the total drops to **~$310 / mo**.

Full cost model: [docs/COST_ESTIMATE.md](../../docs/COST_ESTIMATE.md)
§5.4.

## When to graduate from dry-run

`idle_cleanup_dry_run = true` is set in this example. Flip to `false`
only after:

1. Reviewing **at least 4 weekly cycles** of dry-run output via the
   `idle-cleanup` dashboard
2. Applying `FinOpsException = true` tags to every resource that must
   stay
3. Confirming a paged on-call exists for the alerting SNS topic
4. Confirming AWS Backup or equivalent backs up the EBS volumes / RDS
   instances the cleanup might touch

## Cleanup

```bash
terraform destroy
```

The KMS CMK, CUR S3 bucket, Config bucket, and every DDB audit table
have `prevent_destroy = true` and will refuse to delete. This is
intentional. To destroy intentionally, see
[docs/DISASTER_RECOVERY.md §3.4](../../docs/DISASTER_RECOVERY.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Reference to undeclared variable "slack_webhook_url"` | `variables.tf` was deleted or not committed | The webhook vars are declared in `examples/production/variables.tf`. Restore from git. |
| Slack messages not arriving | Webhook URL malformed or Slack app deactivated | Test with `curl -X POST -d '{"text":"test"}' "$WEBHOOK"` |
| `terraform apply` fails on `aws_config_configuration_recorder` | Account-level Config recorder already exists | Set `tag_governance_enable_config_recorder = false` |
| Idle-cleanup deleted something unexpected | (Shouldn't happen — dry-run is on by default) | Restore from snapshot; check the ACTION row in `<prefix>-idle-findings` DDB table |
| KPI aggregator returns nothing | First CUR has not landed yet (~24–48h after first apply) | Wait. Subsequent days produce data. |
