# examples/minimal

The **Crawl-phase** deployment — the smallest viable Solidus FinOps stack
for a new account that hasn't yet established tagging discipline or an
allocation strategy.

## What this example deploys

✅ Active

- **alerting** — events SNS bus + dispatcher Lambda (always on; one
  email destination via `alerting_legacy_emails`)
- **cost-data-exports** — CUR 2.0 export, Athena workgroup, Glue
  crawler, named-queries library, daily health-check Lambda
- **KMS CMK** — encrypts every framework data plane
- **budgets** — single account-level budget at $5 000/mo (within the
  AWS free tier of 2 budgets)

❌ Disabled — turn on later as the practice matures

- `tag_governance_enabled = false` — no Config rules yet (taxonomy
  TBD)
- `idle_cleanup_enabled = false` — no idle-resource cleanup
- `instance_scheduler_enabled = false` — no start/stop automation
- `finops_metrics_enabled = false` — no daily KPI aggregation (CUR
  needs ≥1 month of data to be useful)
- `cost_data_exports_focus_enabled = false` — CUR 2.0 only (FOCUS
  matters when going multi-cloud)
- No Slack / Teams / PagerDuty channels — email is enough at this
  phase

## Cost expectation

A sandbox account (~200 resources) with no Config recorder costs
approximately **$3–$5 / month**. The dominant line items are:

- KMS CMK: $1.05
- CloudWatch custom metrics (~10 distinct from the dispatcher): ~$1.50
- AWS Budgets: $0 (within free tier)
- S3 + Athena: <$0.10
- Lambda: $0 (free tier)

See [docs/COST_ESTIMATE.md](../../docs/COST_ESTIMATE.md) §5.1 for the
full breakdown.

## Run it

```bash
cd examples/minimal

# AWS credentials must be available (env vars, profile, or instance role)
export AWS_PROFILE=examplebank-shared    # adjust to match your account
export AWS_REGION=eu-central-1

terraform init
terraform plan
terraform apply
```

Apply takes ~3–5 minutes. The Glue crawler discovers the CUR table on
its next scheduled run (06:00 UTC daily); Athena queries become
functional within ~24–48h of the first apply once AWS delivers the
first CUR file.

## Verify it's working

```bash
# 1. Events bus + dispatcher Lambda exist
terraform output events_topic_arn
terraform output framework_status

# 2. CUR export was registered
aws bcm-data-exports list-exports

# 3. The cost-data bucket is encrypted + versioned
aws s3api get-bucket-encryption \
  --bucket "$(terraform output -raw cost_data_exports_bucket_name)"

# 4. The single budget is active
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)"
```

The first email subscriber will get an SNS confirmation message — accept
it from the inbox; until accepted, the address is `PendingConfirmation`
in SNS.

## When to graduate from this example

Move to [`examples/selective`](../selective/) once you have:

- A first taxonomy of mandatory tags (CostCenter / BusinessUnit /
  Application at minimum), AND
- Two consecutive weeks of CUR data flowing into the bucket, AND
- Reviewed at least one weekly cost report from the AWS console.

Move directly to [`examples/production`](../production/) if you also
have a mature paging stack (Slack/Teams/PagerDuty) and want auto-
enforcement of budgets + idle cleanup + scheduling on day one.

## What you'll need to change

`namespace`, `environment`, `aws_primary_region`, and the budget
`amount` should match your account. The `alerting_legacy_emails` value
is a placeholder — set it to a real address the FinOps team monitors.

## Cleanup

```bash
terraform destroy
```

The KMS CMK and CUR S3 bucket have `prevent_destroy = true` and will
refuse to delete. To destroy intentionally, remove the lifecycle
blocks in [main.tf](../../main.tf) (KMS) and
[s3.tf](../../modules/cost-data-exports/s3.tf) (CUR bucket) first, then
re-apply, then destroy. The 30-day KMS deletion window applies.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Reference to undeclared resource` on first plan | Stale `.terraform` from a different root | `rm -rf .terraform .terraform.lock.hcl && terraform init` |
| `BucketAlreadyExists` on apply | Another account already owns the global S3 name | Set `cost_data_exports_bucket_name = "<unique-name>"` or change `namespace` |
| `EntityAlreadyExists` on KMS key alias | A previous Solidus install in this account | Set `create_kms_key = false` and pass `existing_kms_key_arn = "<arn>"` |
| Empty `terraform output framework_status` | Dispatcher Lambda hasn't run yet | Triggered by SNS subscription confirmation; check `/aws/lambda/<prefix>-dispatcher` log |
