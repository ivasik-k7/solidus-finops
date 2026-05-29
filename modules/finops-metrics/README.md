# finops-metrics

Emits named FinOps KPIs to three sinks at once so any consumer can read them: Athena named queries (for BI tools), CloudWatch custom metrics (for alarms), and SSM Parameter Store (for cross-workspace Terraform).

Implements the **Reporting & Analytics**, **Benchmarking**, and **Unit Economics** capabilities of the FinOps Foundation Framework.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for the daily KPI digest. |
| `kms_key_arn` | string | — | CMK for log groups + Lambda env vars. |
| `log_retention_days` | number | — | CloudWatch log retention. |
| `lambda_runtime` | string | — | Python runtime for the aggregator. |
| `athena_workgroup_name` | string | — | Athena workgroup the named queries register against. Comes from `cost-data-exports`. |
| `athena_database_name` | string | — | Glue database holding the CUR table. |
| `cur_table_name` | string | `"cur2"` | Glue table name for CUR 2.0. |
| `allocation_tag_keys` | list(string) | `["CostCenter", "BusinessUnit", "Application"]` | A CUR line is counted as allocated only if it carries all of these tag keys. |
| `aggregator_cron` | string | `"0 7 * * ? *"` | EventBridge cron (UTC) for the daily aggregator. |
| `alarm_thresholds` | object | see [main.tf](main.tf) | Per-KPI alarm bars. Set any to `null` to skip the alarm. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

## Outputs

| Name | Description |
|---|---|
| `aggregator_lambda_arn` | Aggregator Lambda ARN. |
| `dlq_arn` | Aggregator SQS DLQ ARN. |
| `metric_namespace` | CloudWatch namespace (`FinOps/KPIs`). |
| `ssm_prefix` | SSM Parameter Store path prefix (`/<name_prefix>/kpis`). |
| `named_query_ids` | Map of friendly name → Athena named-query ID. |

## What it produces

### Athena named queries (queryable from any BI tool)

| Name | What it computes |
|---|---|
| `<prefix>-kpi-allocation-coverage` | % of unblended cost carrying all `allocation_tag_keys`, current month |
| `<prefix>-kpi-spend-by-service` | Unblended cost by AWS service, current month, sorted desc |
| `<prefix>-kpi-unit-cost-by-business-unit` | Cost per `BusinessUnit` tag value, current month |
| `<prefix>-kpi-month-over-month-growth` | This month vs. last month per service, with % change |

### CloudWatch custom metrics (namespace `FinOps/KPIs`)

| Metric | Source |
|---|---|
| `AllocationCoveragePct` | Athena → CUR |
| `CommitmentCoveragePct` | Cost Explorer (RI + SP coverage, last 30d) |
| `CommitmentUtilizationPct` | Cost Explorer (RI + SP utilization, last 30d) |
| `AnomalyImpactUsdMtd` | Cost Explorer (anomalies, month-to-date) |
| `ForecastAbsDriftPct` | Cost Explorer (actual MTD vs. forecast) |
| `SpendByServiceUsd` (per `Service` dimension) | Athena → CUR (top 10) |

### SSM Parameter Store (path `/<name_prefix>/kpis/`)

Scalar KPIs are mirrored under `/{name_prefix}/kpis/{snake_case_name}` so other Terraform workspaces can read them without state-sharing.

### Built-in CloudWatch alarms

Four threshold alarms ship with sensible defaults, each routed to the events topic. Set any threshold to `null` in `alarm_thresholds` to disable:

| Alarm | Default threshold |
|---|---|
| AllocationCoveragePct < N | 80% |
| CommitmentCoveragePct < N | 70% |
| CommitmentUtilizationPct < N | 80% |
| ForecastAbsDriftPct > N | 15% |

## Design notes

- **One Lambda, three sinks.** Computing the same value three times would mean three places where they could drift. The aggregator computes once and writes to all three.
- **Independent KPI failures.** If Cost Explorer is throttled, Athena still publishes its KPIs; only the failing one is reported in the error list. The Lambda still raises at the end so SNS treats the invocation as failed (and the DLQ catches it), but partial data lands.
- **Athena queries are versioned in Terraform.** Changing a KPI definition is a code change with a PR review — exactly the property `cost-categories` already gives us for allocation logic.
- **SSM mirror is opinionated.** Only scalar KPIs go to SSM (parameters are strings). Per-dimension metrics like `SpendByServiceUsd` only land in CloudWatch.
- **No `prevent_destroy`.** Unlike cost-data buckets, KPI metrics are derived data — they can always be recomputed by re-running the Lambda.
- **Daily schedule, not hourly.** CUR 2.0 refreshes a few times per day. More-frequent aggregation costs Athena scans without producing new information.
