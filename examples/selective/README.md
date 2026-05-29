# examples/selective

A **pick-and-choose deployment**: enable exactly the modules you want, leave the rest off. Every disabled module is a one-line flip away from enabled — no other code changes needed.

## What this example deploys

✅ Active
- **budgets** — polymorphic budgets + AWS Budget Actions + daily performance Lambda + DDB trend store + CloudWatch dashboard
- **idle-resource-cleanup** — 6 resource types (EBS, EIP, snapshot, NAT, ENI, LB) with DDB-backed state, multi-region scanning, two-phase EBS deletion
- **tag-governance** — required-tag Config rules, tag-drift detection, allocation Resource Groups, tag taxonomy as code
- **alerting** — events SNS bus + chat-notifier (always on; events bus is required infrastructure)
- **KMS CMK** — encrypts S3, SNS, DynamoDB, Secrets Manager, CloudWatch Logs (always on)

❌ Disabled (one flag flip to enable)
- cost-data-exports, instance-scheduler, finops-metrics, tag_governance untagged-cost-report

## Module enable matrix

| Module | Flag | Default | Notes |
|---|---|---|---|
| alerting (events bus) | — | always on | Required infrastructure; not disable-able |
| KMS CMK | `create_kms_key` | `true` | Set `false` + provide `existing_kms_key_arn` to BYO |
| cost-data-exports | `cost_data_exports_enabled` | `true` | CUR 2.0 + FOCUS + Athena + Glue crawler. Required by finops-metrics + untagged-cost-report. |
| tag-governance | `tag_governance_enabled` | `true` | Config rules + drift + Resource Groups |
| idle-resource-cleanup | `idle_cleanup_enabled` | `false` | Off by default; this example turns it on |
| instance-scheduler | `instance_scheduler_enabled` | `false` | Off by default |
| finops-metrics | `finops_metrics_enabled` | `true` | Requires `cost_data_exports_enabled` + `cost_data_exports_athena_enabled` |
| budgets (whole module) | _implicit_ — `var.budgets_items` | `{}` | Set non-empty map to provision |
| budgets performance Lambda | `budgets_performance_tracking_enabled` | `true` | Inside the budgets module; only relevant when budgets is provisioned |
| tag-governance untagged-cost report | `tag_governance_untagged_cost_report_enabled` | `false` | Requires Athena |
| tag-governance drift detection | `tag_governance_drift_detection_enabled` | `true` | EventBridge on `aws.tag` |

## Enabling a disabled module — playbook

### …add cost-data-exports + finops-metrics (full FinOps stack)
```hcl
cost_data_exports_enabled        = true
cost_data_exports_focus_enabled  = true
cost_data_exports_athena_enabled = true
finops_metrics_enabled           = true
```
First-apply note: the Glue crawler + first CUR delivery take **~24–48h** before Athena queries return data. Until then, finops-metrics + untagged-cost reports are non-functional (but no errors).

### …add instance scheduler
```hcl
instance_scheduler_enabled        = true
instance_scheduler_opt_in_tag_key = "Schedule"
instance_scheduler_schedules = {
  office-hours-cet = {
    days     = ["MON", "TUE", "WED", "THU", "FRI"]
    start    = "08:00"
    stop     = "18:00"
    timezone = "Europe/Berlin"
  }
}
```
Tag your EC2 instances `Schedule=office-hours-cet` to opt them in.

### …add a tag-governance untagged-cost report (dollarize the tag gap)
```hcl
# Requires cost-data-exports + Athena to be on:
cost_data_exports_enabled                        = true
cost_data_exports_athena_enabled                 = true
tag_governance_untagged_cost_report_enabled      = true
tag_governance_untagged_cost_alarm_threshold_usd = 5000
```

### …add a tag-scoped budget
```hcl
budgets_items = merge(local.existing_budgets, {
  retail_monthly = {
    scope  = "tag"
    amount = 50000
    target = { tag_key = "BusinessUnit", tag_value = "retail" }
  }
})
```

## Run it

```bash
cd examples/selective
terraform init
terraform plan
terraform apply
```

In TFE, point the workspace's working directory at `examples/selective` and set:
- `alerting_legacy_emails` — list of emails
- `alerting_slack_webhook_url` / `alerting_teams_webhook_url` — sensitive (uncomment in main.tf)

## Cost expectation for this configuration

See [docs/COST_ESTIMATE.md](../../docs/COST_ESTIMATE.md) for the full breakdown. Quick estimate for this exact mix (small/medium account, ~2k resources):

| Component | Monthly |
|---|---|
| KMS + Secrets Manager + budgets baseline | ~$3 |
| Budgets (3 budgets) | ~$0.62 (1 paid × $0.62) |
| DynamoDB (budgets + idle-cleanup state tables, on-demand) | <$1 |
| Lambda compute (4 active Lambdas) | $0 (free tier) |
| CloudWatch (metrics + alarms + dashboards) | ~$1 |
| AWS Config recording (4-tag rule, ~50k CI/mo) | **~$170**  |
| **Estimated total** | **~$175 / mo** |

**Largest variable**: AWS Config. If your account already has Config enabled at the org level, the framework's tag-governance module re-uses that recorder — drop `enable_config_recorder = false` and the total drops to ~$10–15/mo.
