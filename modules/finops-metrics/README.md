# finops-metrics

A **standalone, reusable** daily FinOps KPI aggregator. Joins data from CUR (via Athena) and AWS Cost Explorer, emits four sinks (CloudWatch metrics + SSM + DDB snapshots + optional SNS digest), keeps a year of history for trend math, and auto-rebuilds its own CloudWatch dashboard with per-tag-value panels and any custom KPIs you define.

Implements the **Reporting & Analytics**, **Benchmarking**, and **Unit Economics** capabilities of the FinOps Foundation Framework.

**Standalone-reusable** — no hard dependency on any sibling module. Bring an Athena workgroup + CUR table, get a daily KPI surface and a self-maintaining dashboard.

## Module layout

```
modules/finops-metrics/
├── main.tf           header only — module is split by concern
├── versions.tf       Terraform + provider version constraints
├── variables.tf      input contract (all variables + validations)
├── outputs.tf        output contract
├── locals.tf         computed locals (env vars, CUR predicate, custom-KPI substitution)
├── data.tf           caller_identity / partition / region data sources
├── iam.tf            aggregator IAM role + policy
├── dynamodb.tf       KPI snapshot history table (drives trend math)
├── sqs.tf            aggregator DLQ
├── athena.tf         built-in + user-defined named queries
├── lambda.tf         aggregator Lambda + log group + archive_file
├── eventbridge.tf    daily trigger
├── cloudwatch.tf     Lambda-self + KPI-threshold + WoW-drift + custom-KPI alarms + base dashboard
├── lambda/
│   └── kpi_aggregator.py
├── docs/
│   └── EDGE_CASES.md    every operational edge case handled
├── CHANGELOG.md      module version history (SemVer)
└── README.md
```

If you're operating the module at scale, **read [docs/EDGE_CASES.md](docs/EDGE_CASES.md) first** — it covers new-account conditions, CUR/Cost-Explorer quirks, the dashboard ownership model (Terraform skeleton + Lambda rebuilds), and the day-1–3 forecast skip.

## Standalone usage (outside the FinOps framework)

```hcl
module "finops_metrics" {
  source = "git::https://github.com/your-org/finops-framework-demo.git//modules/finops-metrics?ref=v1.0.0"

  name_prefix = "myproject"
  kms_key_arn = aws_kms_key.shared.arn

  # Comes from cost-data-exports (or wherever you provisioned Athena + CUR)
  athena_workgroup_name = aws_athena_workgroup.shared.name
  athena_database_name  = aws_glue_catalog_database.cur.name
  cur_table_name        = "cur2"

  # Optional — if omitted, the aggregator skips the SNS digest entirely.
  # CloudWatch metrics, SSM mirror, DDB snapshots, and dashboard still work.
  # events_topic_arn = aws_sns_topic.alerts.arn

  # Optional — turn off built-in KPIs your analytics tool already provides
  builtin_kpis_enabled = {
    commitment_coverage    = false  # Cloudability owns this for us
    commitment_utilization = false
  }

  # Optional — discover BusinessUnit values from CUR + auto-render widgets
  tag_value_dashboard_tag = "BusinessUnit"

  # Optional — user-defined KPIs. Each becomes a named query + a metric + (optional) alarm.
  custom_kpis = {
    cost_per_transaction = {
      description = "Account spend / daily transaction count"
      sql = <<-SQL
        SELECT ROUND(SUM(line_item_unblended_cost) / 100000.0, 4)
        FROM ${"$"}{cur}
        WHERE billing_period = date_format(current_date, '%Y-%m')
      SQL
      unit = "None"
      alarm = {
        comparison = "GreaterThan"
        threshold  = 0.50
      }
    }
  }

  default_tags = { Owner = "finops-team" }
}
```

That's it. After the first daily aggregator run (within 24h of apply), CloudWatch has the KPI metrics, SSM has scalar mirrors, DDB has the first day's snapshot row, and the dashboard is populated.

## Inputs

### Required

| Name | Type | Description |
|---|---|---|
| `name_prefix` | string | Naming prefix |
| `kms_key_arn` | string | CMK for DDB, log group, Lambda env |
| `athena_workgroup_name` | string | Athena workgroup (from cost-data-exports) |
| `athena_database_name` | string | Glue database holding the CUR table |

### Optional plumbing

| Name | Default | Description |
|---|---|---|
| `events_topic_arn` | `null` | SNS topic for digest + alarm actions. NULL = standalone mode |
| `cur_table_name` | `"cur2"` | Glue table name for CUR 2.0 |
| `log_retention_days` | `365` | CloudWatch log retention |
| `lambda_runtime` | `"python3.12"` | Python runtime |
| `default_tags` | `{}` | Tags applied to every resource |

### Schedule + allocation

| Name | Default | Description |
|---|---|---|
| `aggregator_cron` | `"0 7 * * ? *"` | UTC cron, six-field |
| `allocation_tag_keys` | `["CostCenter", "BusinessUnit", "Application"]` | Tag keys a line must carry to count as allocated. Empty list disables allocation_coverage. |

### KPI control

| Name | Default | Description |
|---|---|---|
| `builtin_kpis_enabled` | all true | Per-KPI on/off: `{allocation_coverage, commitment_coverage, commitment_utilization, anomaly_impact, forecast_drift, spend_by_service}` |
| `custom_kpis` | `{}` | Map of user-defined KPIs (Athena SQL + optional alarm). See standalone-usage example. |
| `alarm_thresholds` | sensible defaults | Per-KPI absolute-threshold alarms |

### Trend metrics + dashboard

| Name | Default | Description |
|---|---|---|
| `trend_metrics_enabled` | `true` | Emit `<Metric>_7dAvg`, `<Metric>_30dAvg`, `<Metric>_WoWDriftPct` for each scalar KPI |
| `wow_drift_alarm_threshold_pct` | `5` | Alarm if AllocationCoveragePct drops > N% WoW |
| `snapshot_retention_days` | `400` | DDB snapshot TTL. ≥35 enforced (need 30d window) |
| `tag_value_dashboard_tag` | `null` | Set to e.g. `"BusinessUnit"` to auto-discover values + render per-value widgets |
| `tag_value_dashboard_top_n` | `12` | Max widgets to render (0..30) |

## Outputs

| Name | Description |
|---|---|
| `aggregator_lambda_arn` / `aggregator_lambda_function_name` | Aggregator Lambda |
| `dlq_arn` | Aggregator DLQ |
| `metric_namespace` | `FinOps/KPIs` |
| `ssm_prefix` | `/<name_prefix>/kpis` |
| `snapshot_table_name` / `snapshot_table_arn` | KPI snapshot DDB |
| `dashboard_name` / `dashboard_url` | Auto-provisioned CloudWatch dashboard |
| `named_query_ids` | Map of named-query name → ID (built-in + custom) |
| `enabled_kpis` | Map showing which KPIs are on for downstream tooling |
| `custom_kpi_metric_names` | List of `Custom_<key>` metric names |

## CloudWatch metrics

### Scalar (mirrored to SSM)

| Metric | Source | Toggle |
|---|---|---|
| `AllocationCoveragePct` | Athena over CUR | `builtin_kpis_enabled.allocation_coverage` |
| `CommitmentCoveragePct` | Cost Explorer (RI + SP coverage) | `builtin_kpis_enabled.commitment_coverage` |
| `CommitmentUtilizationPct` | Cost Explorer (RI + SP utilization) | `builtin_kpis_enabled.commitment_utilization` |
| `AnomalyImpactUsdMtd` | Cost Explorer (anomalies, MTD) | `builtin_kpis_enabled.anomaly_impact` |
| `ForecastAbsDriftPct` | Cost Explorer (actual MTD vs. projected) | `builtin_kpis_enabled.forecast_drift` |
| `Custom_<key>` (per custom KPI) | Athena over user SQL | one per `var.custom_kpis` entry |

### Dimensioned (CloudWatch only)

| Metric | Dimensions | Source |
|---|---|---|
| `SpendByServiceUsd` | `Service` | Athena over CUR (top 10/month) |
| `SpendByTagValueUsd` | `TagKey`, `TagValue` | Athena over CUR, gated by `tag_value_dashboard_tag` |

### Derived (when `trend_metrics_enabled = true`)

For every scalar KPI:
- `<Metric>_7dAvg` — 7-day moving average from DDB
- `<Metric>_30dAvg` — 30-day moving average from DDB
- `<Metric>_WoWDriftPct` — this-week-avg vs last-week-avg, %. Negative = degradation.

## DynamoDB schema

```
PK = "KPI#<MetricName>"     e.g. "KPI#AllocationCoveragePct"
SK = "<YYYY-MM-DD>"          one row per day per KPI
    MetricName, Value (Decimal), Unit, GeneratedAt
    ExpireAt — TTL (snapshot_retention_days, default 400d)
```

Query patterns:
- **One KPI's full history**: `Query` where `PK = "KPI#AllocationCoveragePct"`, range over SK.
- **All KPIs on a given date**: scan with `SK = "2026-05-29"` (use sparingly, or add a GSI in v2).

## Alarms

| Alarm | Trigger | Notes |
|---|---|---|
| Aggregator Lambda errors | `AWS/Lambda Errors > 0` for 5min | always on; actions = events_topic if set |
| Aggregator DLQ depth | `AWS/SQS ApproximateNumberOfMessagesVisible > 0` | always on |
| AllocationCoverage low | `< alarm_thresholds.allocation_coverage_min_pct` | gated by built-in toggle + threshold not null |
| CommitmentCoverage low | `< alarm_thresholds.commitment_coverage_min_pct` | same gating |
| CommitmentUtilization low | `< alarm_thresholds.commitment_utilization_min_pct` | same gating |
| ForecastDrift high | `> alarm_thresholds.forecast_accuracy_max_drift_pct` | same gating |
| AllocationCoverage WoW drift | `< -wow_drift_alarm_threshold_pct` | gated by trends + threshold not null |
| Custom KPI breach | one per `custom_kpis.<key>.alarm` | comparison + threshold from caller |

## Design notes

- **Four sinks, one compute.** The aggregator computes each KPI once and writes to CloudWatch, SSM, DDB, and SNS. No drift across consumers.
- **Per-KPI failure isolation.** Cost Explorer throttling on one KPI doesn't stop Athena KPIs from publishing. The Lambda still raises at the end so the DLQ catches a copy.
- **Standalone-mode by design.** `events_topic_arn = null` is a first-class state. CloudWatch + SSM + DDB + dashboard all work without it.
- **Trends from history, not heuristics.** Moving averages and WoW drift are computed from DDB snapshots — actual past values, not approximations.
- **Custom KPIs are first-class.** They get the same treatment as built-in KPIs: named query, metric, SSM mirror, DDB snapshot, optional alarm, dashboard widget.
- **Dashboard rebuild on every run.** Per-tag-value widgets and custom-KPI widgets are picked up automatically — no Terraform apply needed to see them. `ignore_changes = [dashboard_body]` prevents CI drift noise.
- **Day 1–3 forecast skip.** AWS Cost Forecast is noisy that early in a month; we deliberately skip rather than emit a misleading number.
- **Daily, not hourly.** CUR refreshes a few times/day; sub-day aggregation would scan Athena for the same data.

## When you outgrow this module

- **Cross-account roll-up** — today the aggregator only sees CUR data for the account it runs in. Multi-payer / multi-account requires querying a consolidated CUR.
- **Per-AccountId widgets** — same idea, sliced by linked-account ID.
- **GSI on the DDB snapshot table** — for "all KPIs on date X" scans at scale.
- **Streaming KPIs to a TSDB** — if CloudWatch's 15-month retention isn't enough; emit to Timestream or push to Prometheus via a sidecar.
- **Anomaly correlation** — join anomalies to the day's KPI drift to highlight cause-effect.
