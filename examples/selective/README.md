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
- cost-data-exports, anomaly-detection, optimization-services, instance-scheduler, savings-coverage-reporter, finops-metrics, cost-categories, untagged-cost-report

## Module enable matrix

| Module | Flag | Default | Notes |
|---|---|---|---|
| alerting (events bus) | — | always on | Required infrastructure; not disable-able |
| KMS CMK | `create_kms_key` | `true` | Set `false` + provide `existing_kms_key_arn` to BYO |
| cost-data-exports | `enable_cost_data_exports` | `true` | CUR 2.0 + FOCUS + Athena + Glue crawler. Required by finops-metrics + untagged-cost-report. |
| anomaly-detection | `enable_anomaly_detection` | `true` | Cost Anomaly Detection service-level monitor |
| cost-categories | _implicit_ — `var.cost_categories` | `{}` | Set non-empty map to provision |
| tag-governance | `enable_tag_governance` | `true` | Config rules + drift + Resource Groups |
| optimization-services | `enable_compute_optimizer` + `enable_cost_optimization_hub` | `true` + `true` | Both flags must be `false` to fully disable |
| idle-resource-cleanup | `enable_idle_cleanup` | `false` | Off by default; this example turns it on |
| instance-scheduler | `enable_instance_scheduler` | `false` | Off by default |
| savings-coverage-reporter | `enable_savings_coverage_reporter` | `true` | Weekly RI/SP coverage digest |
| finops-metrics | `enable_finops_metrics` | `true` | Requires `enable_cost_data_exports` + `enable_athena_workgroup` |
| budgets (whole module) | _implicit_ — `var.budgets` | `{}` | Set non-empty map to provision |
| budgets performance Lambda | `enable_budget_performance_tracking` | `true` | Inside the budgets module; only relevant when budgets is provisioned |
| tag-governance untagged-cost report | `enable_untagged_cost_report` | `false` | Requires Athena |
| tag-governance drift detection | `enable_tag_drift_detection` | `true` | EventBridge on `aws.tag` |

## Enabling a disabled module — playbook

### …add cost-data-exports + finops-metrics (full FinOps stack)
```hcl
enable_cost_data_exports = true
enable_focus_export      = true
enable_athena_workgroup  = true
enable_finops_metrics    = true
```
First-apply note: the Glue crawler + first CUR delivery take **~24–48h** before Athena queries return data. Until then, finops-metrics + untagged-cost reports are non-functional (but no errors).

### …add anomaly detection
```hcl
enable_anomaly_detection  = true
anomaly_min_impact_amount = 100
anomaly_min_impact_pct    = 20
```
First-month note: AWS Cost Anomaly Detection needs ~14 days to build a usage baseline.

### …add instance scheduler
```hcl
enable_instance_scheduler         = true
instance_scheduler_opt_in_tag_key = "Schedule"
instance_scheduler_schedules = {
  office-hours-cet = {
    start_cron = "0 6 ? * MON-FRI *"
    stop_cron  = "0 18 ? * MON-FRI *"
  }
}
```
Tag your EC2 instances `Schedule=office-hours-cet` to opt them in.

### …add cost categories + cost-category-scoped budgets
```hcl
cost_categories = {
  BusinessUnit = {
    default_value = "unallocated"
    rules = [
      { value = "retail", rule = { tags = { key = "BusinessUnit", values = ["retail"], match_options = ["EQUALS"] } } },
    ]
  }
}

budgets = merge(local.existing_budgets, {
  retail_monthly = {
    scope  = "cost_category"
    amount = 50000
    target = { category_name = "BusinessUnit", category_value = "retail" }
  }
})
```

### …add savings coverage reporter
```hcl
enable_savings_coverage_reporter = true
savings_coverage_target_pct      = 70
```
Most useful once you have a non-trivial RI/SP footprint (≥ $10k/mo committed).

### …add Compute Optimizer + Cost Optimization Hub
```hcl
enable_compute_optimizer     = true
enable_cost_optimization_hub = true
```
Both free.

## Run it

```bash
cd examples/selective
terraform init
terraform plan
terraform apply
```

In TFE, point the workspace's working directory at `examples/selective` and set:
- `notification_emails` — list of emails
- `slack_webhook_url` / `teams_webhook_url` — sensitive (uncomment in main.tf)

## Cost expectation for this configuration

See [docs/COST_ESTIMATE.md](../../docs/COST_ESTIMATE.md) for the full breakdown. Quick estimate for this exact mix (small/medium account, ~2k resources):

| Component | Monthly |
|---|---|
| KMS + Secrets Manager + budgets baseline | ~$3 |
| Budgets (5 budgets) | ~$1.86 (3 paid × $0.62) |
| DynamoDB (budgets + idle-cleanup state tables, on-demand) | <$1 |
| Lambda compute (4 active Lambdas) | $0 (free tier) |
| CloudWatch (metrics + alarms + dashboards) | ~$1 |
| AWS Config recording (4-tag rule, ~50k CI/mo) | **~$170**  |
| **Estimated total** | **~$175 / mo** |

**Largest variable**: AWS Config. If your account already has Config enabled at the org level, the framework's tag-governance module re-uses that recorder — drop `enable_config_recorder = false` and the total drops to ~$10–15/mo.
