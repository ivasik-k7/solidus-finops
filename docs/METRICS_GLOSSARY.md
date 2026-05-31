# Solidus FinOps — Metrics Glossary

**Audience:** Analytics consumers, dashboard authors, alarm tuners,
external monitoring integrators. **As-of:** 2026-05-31.

Exact definitions of every CloudWatch metric, dimension, unit, and
emission cadence the framework publishes. Pairs with
[OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md) for *how to respond*
when these metrics breach thresholds.

---

## 1. Namespaces — at a glance

| Namespace | Emitter | What it covers |
|---|---|---|
| `FinOps/Alerting` | dispatcher Lambda | Event-bus dispatch counts |
| `FinOps/Budgets` | budget-performance Lambda | Per-budget variance, burn-rate, fleet adherence |
| `FinOps/CostDataExports` | cost-data health-check Lambda | CUR freshness, crawler health, Athena queryability |
| `FinOps/IdleResources` | 6 idle-cleanup Lambdas | Per-resource-type waste, findings, savings |
| `FinOps/InstanceScheduler` | scheduler Lambda | Per-tick action counts, managed resource counts |
| `FinOps/KPIs` | kpi-aggregator Lambda | Allocation %, commitment coverage/utilization, anomaly impact, forecast drift, custom KPIs |
| `FinOps/TagGovernance` | untagged-cost report Lambda | Untagged-cost dollar gap |

All metrics have a **module-owned** namespace — no cross-namespace
pollution. Search for any metric across the framework:

```bash
aws cloudwatch list-metrics --namespace "FinOps/*"
```

CloudWatch's "first 10 000 metrics @ $0.30/metric/mo" pricing tier
makes the metric count a real cost driver — see
[COST_ESTIMATE.md §3.13](COST_ESTIMATE.md).

---

## 2. `FinOps/Alerting` — dispatcher

Emitter: `<name_prefix>-dispatcher` Lambda. Emission: per-invocation.

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `EventsDispatched` | Count | `Channel` ∈ {`slack`, `teams`, `pagerduty`, `opsgenie`, `email`, `generic_webhook`, `sqs`} | Number of events successfully posted to a destination this invocation |
| `EventsDeduped` | Count | — | Events suppressed by the dedup cache (fingerprint already in DDB within `window_minutes`) |
| `EventsBelowSeverity` | Count | `Channel` | Events filtered out because severity < channel's `min_severity` |
| `DispatchErrors` | Count | `Channel` | HTTP non-2xx, SDK exception, secret-fetch failure, etc. Lands in DLQ via Lambda's standard failure path. |

**Built-in alarms**: `<name_prefix>-dispatcher-errors` (AWS/Lambda
Errors > 0); `<name_prefix>-dispatcher-dlq-depth`.

---

## 3. `FinOps/Budgets` — budget-performance

Emitter: `<name_prefix>-budget-perf` Lambda. Emission: daily.

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `VariancePct` | Percent | `Budget` (= `<name_prefix>-<budget_key>`) | `(actual_mtd / budget_amount - 1) * 100`. Negative = under-budget; positive = over. |
| `BurnRateDaysToBreach` | Count (days) | `Budget` | Projected days until the budget breaches at the current daily spend rate. Infinity if not on track to breach. |
| `BudgetAdherenceScore` | Percent | — | % of all budgets whose `VariancePct < 0` today (i.e., within target). Fleet-wide health KPI. |
| `ActiveBudgetCount` | Count | — | How many budgets the Lambda actually saw on this run. |
| `AnomalyCorrelationCount` | Count | `Budget` | How many Cost Anomaly Detection findings overlap with this budget's scope and time window. Drives the digest "is this breach really an anomaly?" line. |

**Built-in alarms**:
- `<name_prefix>-budget-perf-errors` + `-dlq-depth` (Lambda self-health)
- `<name_prefix>-budget-adherence-low` — `BudgetAdherenceScore <
  var.adherence_alarm_threshold` (default 80)
- `<name_prefix>-budget-burn-rate-low` — metric-math alarm. Takes MIN
  across every budget's `BurnRateDaysToBreach` and fires when that MIN
  drops below `var.burn_rate_alarm_days_to_breach` (default 7).

**Where to look for context**: DDB `<name_prefix>-budgets-state` —
the STATE row carries actual_mtd, the SNAPSHOT row carries 90 days
of trend, and ACTION rows audit every Budget Action firing.

---

## 4. `FinOps/CostDataExports` — health-check Lambda

Emitter: `<name_prefix>-cost-data-health` Lambda. Emission: daily.

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `CurDeliveryHours` | Count (hours) | — | Hours since the most recent CUR parquet file landed in S3. Fresh delivery = ≤ 24h. |
| `CrawlerLastRunHours` | Count (hours) | — | Hours since the Glue crawler's last successful run. Healthy = ≤ 25h (daily schedule + slack). |
| `AthenaQueryability` | Count (0 or 1) | — | 1 if a probe `SELECT 1` against the CUR table succeeded this run, 0 if not. |
| `BucketObjectCount` | Count | — | Total objects in the cost-data bucket. Steady growth normal; sharp drop = lifecycle policy aggressive. |

**Built-in alarms**:
- `<name_prefix>-cost-data-health-errors` (Lambda self-health)
- `<name_prefix>-cur-delivery-stale` — `CurDeliveryHours >
  var.cur_freshness_alarm_hours` (default 36)

---

## 5. `FinOps/IdleResources` — 6 cleanup Lambdas

Each cleanup Lambda emits the same shape with a different
`ResourceType` dimension.

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `FoundCount` | Count | `ResourceType` ∈ {`EBS`, `EIP`, `EBSSnapshot`, `NATGateway`, `ENI`, `LoadBalancer`} | Resources matching the idle criteria on this run. Pre-action filter. |
| `MonthlyWasteUsd` | None (USD) | `ResourceType` | Estimated wasted USD/month from FoundCount × per-type unit cost (EBS $/GB-mo, EIP $3.6/mo, NAT $32/mo at on-demand list). |
| `ActionsTakenCount` | Count | `ResourceType` | Resources actually acted on this run (delete/release/snapshot). Equals 0 in dry-run mode. |
| `RunSavingsUsd` | None (USD) | `ResourceType` | USD/month saved by *this run's* actions. ActionsTakenCount × per-type unit cost. |
| `ExceptedCount` | Count | `ResourceType` | Resources matching idle criteria but excluded by `FinOpsException` tag. |
| `SnoozedCount` | Count | `ResourceType` | Resources currently in `Status="snoozed"` per the DDB STATE row. |

**Built-in alarms** (per resource type):
- `<name_prefix>-idle-{type}-errors` (Lambda self-health)
- `<name_prefix>-idle-{type}-dlq-depth` (DLQ depth)
- **Aggregate** `<name_prefix>-idle-total-waste` — metric-math alarm
  over `SUM(MonthlyWasteUsd)` across all `ResourceType` dimensions.
  Fires when total monthly waste > `var.total_waste_alarm_threshold_usd`
  (default 500).

**ResourceType labels** are the canonical values; the dashboard uses
these exact strings. Aliases are documented in
[modules/idle-resource-cleanup/locals.tf](../modules/idle-resource-cleanup/locals.tf)
`resource_type_label`.

---

## 6. `FinOps/InstanceScheduler` — scheduler Lambda

Emitter: `<name_prefix>-scheduler` Lambda. Emission: per-tick (5-min default).

### Action counters (per-tick)

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `ActionStarted` | Count | — | Resources started this tick |
| `ActionStopped` | Count | — | Resources stopped this tick |
| `ActionSkippedOverride` | Count | — | Resources within their schedule's "active" window but tagged `ScheduleOverrideUntil` |
| `ActionSkippedCeiling` | Count | — | Resources that would have been acted on but `max_actions_per_tick` was already reached |
| `ActionSkippedSpot` | Count | — | EC2 instances with `InstanceLifecycle == "spot"` that the scheduler refused to manage (requires `enable_spot_management = true`) |
| `ActionScaleAmbiguous` | Count | — | ASG scale-to-zero attempts where the `Desired` count was outside [0, MaxSize] before the scheduler touched it (manual override in flight) |
| `ActionDryRun` | Count | — | Actions that would have fired but didn't because `dry_run = true` |
| `ActionFailed` | Count | — | AWS API errors during start/stop (rare; logged + alarmed) |

### Resource-state counters

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `ManagedResourceCount` | Count | `ResourceType` ∈ {`EC2`, `RDSInstance`, `RDSCluster`, `ASG`} | How many resources of each type the scheduler currently considers in-scope |

### Built-in alarms

- `<name_prefix>-scheduler-errors` + `-dlq-depth`
- `<name_prefix>-scheduler-discovery-errors`
- (No KPI-threshold alarms on scheduler counts by default — count
  semantics vary too much across deployments to ship a meaningful
  default.)

---

## 7. `FinOps/KPIs` — KPI aggregator

Emitter: `<name_prefix>-kpi-aggregator` Lambda. Emission: daily.

### Scalar KPIs (also SSM-mirrored)

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `AllocationCoveragePct` | Percent | — | `% of unblended_cost where ALL var.allocation_tag_keys are present`. Driven by Athena over CUR. |
| `CommitmentCoveragePct` | Percent | — | `min(100, ri_coverage_pct + sp_coverage_pct)`. RI+SP combined coverage over eligible compute, last 30 days. |
| `CommitmentUtilizationPct` | Percent | — | Average of `ri_utilization_pct` and `sp_utilization_pct` (whichever are non-zero), last 30 days. |
| `AnomalyImpactUsdMtd` | None (USD) | — | Sum of `Impact.TotalImpact` across all `ce:GetAnomalies` results for the current month. |
| `ForecastAbsDriftPct` | Percent | — | Absolute % drift between actual MTD spend and the projected MTD spend implied by AWS forecast. Skipped on days 1–3 of the month. |

### Per-service spend (dimensioned, no SSM mirror)

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `SpendByServiceUsd` | None (USD) | `Service` (AWS service name from CUR) | Top-10 services by current-month unblended cost. ~10 metrics. |

### Per-tag-value spend (gated by `var.tag_value_dashboard_tag`)

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `SpendByTagValueUsd` | None (USD) | `TagKey`, `TagValue` | Current-month spend grouped by the configured allocation tag. Emitted per distinct value — cardinality = number of distinct values. |

### Trend metrics (gated by `var.trend_metrics_enabled`, default `true`)

For each scalar KPI listed above, the aggregator also emits:

| Metric pattern | Unit | Meaning |
|---|---|---|
| `<Metric>_7dAvg` | (same as base) | 7-day moving average from DDB snapshot history |
| `<Metric>_30dAvg` | (same as base) | 30-day moving average |
| `<Metric>_WoWDriftPct` | Percent | This-week-avg vs last-week-avg, %. Negative = degradation. |

Example: `AllocationCoveragePct`, `AllocationCoveragePct_7dAvg`,
`AllocationCoveragePct_30dAvg`, `AllocationCoveragePct_WoWDriftPct`.

### Custom KPIs (one per `var.custom_kpis` entry)

| Metric pattern | Unit | Meaning |
|---|---|---|
| `Custom_<key>` | `var.custom_kpis.<key>.unit` (default "None") | User-supplied Athena query result. Also gets trend variants if `trend_metrics_enabled` is on. |

### Built-in alarms

| Alarm | Condition |
|---|---|
| `<name_prefix>-kpi-aggregator-errors` | Lambda self-health |
| `<name_prefix>-kpi-aggregator-dlq-depth` | DLQ depth > 0 |
| `<name_prefix>-kpi-allocation-coverage-low` | `AllocationCoveragePct < var.alarm_thresholds.allocation_coverage_min_pct` (default 80) |
| `<name_prefix>-kpi-commitment-coverage-low` | `CommitmentCoveragePct < var.alarm_thresholds.commitment_coverage_min_pct` (default 70) |
| `<name_prefix>-kpi-commitment-utilization-low` | `CommitmentUtilizationPct < var.alarm_thresholds.commitment_utilization_min_pct` (default 80) |
| `<name_prefix>-kpi-forecast-drift-high` | `ForecastAbsDriftPct > var.alarm_thresholds.forecast_accuracy_max_drift_pct` (default 15) |
| `<name_prefix>-kpi-allocation-coverage-wow-drift` | `AllocationCoveragePct_WoWDriftPct < -var.wow_drift_alarm_threshold_pct` (default 5) |
| `<name_prefix>-kpi-custom-<key>` | One per custom KPI with `alarm = { comparison, threshold }` |

---

## 8. `FinOps/TagGovernance` — untagged-cost report

Emitter: `<name_prefix>-untagged-cost-report` Lambda. Emission: weekly.

| Metric | Unit | Dimensions | Meaning |
|---|---|---|---|
| `TotalUntaggedCostUsd` | None (USD) | — | Sum of unblended cost across resources missing at least one mandatory allocation tag, current month. |
| `UntaggedCostByTagKeyUsd` | None (USD) | `TagKey` (one per mandatory tag) | Cost where this specific tag is missing or empty, current month. |
| `UntaggedResourceCountByService` | Count | `Service` (AWS service name) | Count of distinct resources where any mandatory tag is missing, by service. |
| `TagCoveragePct` | Percent | `TagKey` | `% of unblended_cost where this tag IS present`. Inverse of "untagged %". |

### Built-in alarms

- `<name_prefix>-untagged-cost-errors` + `-dlq-depth`
- `<name_prefix>-untagged-cost-excess` — `TotalUntaggedCostUsd >
  var.untagged_cost_alarm_threshold_usd` (default $1 000). 7-day
  alarm period (aligned to weekly emission cadence).

---

## 9. SSM Parameter Store mirrors

Scalar KPIs are mirrored to SSM Parameter Store so other Terraform
workspaces / external tools can read them without CloudWatch API
quotas. Path conventions:

| Origin metric | SSM path |
|---|---|
| `FinOps/KPIs/AllocationCoveragePct` | `/<name_prefix>/kpis/allocation_coverage_pct` |
| `FinOps/KPIs/CommitmentCoveragePct` | `/<name_prefix>/kpis/commitment_coverage_pct` |
| `FinOps/KPIs/CommitmentUtilizationPct` | `/<name_prefix>/kpis/commitment_utilization_pct` |
| `FinOps/KPIs/AnomalyImpactUsdMtd` | `/<name_prefix>/kpis/anomaly_impact_usd_mtd` |
| `FinOps/KPIs/ForecastAbsDriftPct` | `/<name_prefix>/kpis/forecast_abs_drift_pct` |
| `FinOps/KPIs/Custom_<key>` | `/<name_prefix>/kpis/custom_<key>` |
| `FinOps/Budgets/BudgetAdherenceScore` | `/<name_prefix>/budgets/budget_adherence_score` |
| `FinOps/TagGovernance/TotalUntaggedCostUsd` | `/<name_prefix>/tag-governance/total_untagged_cost_usd` |

Dimensioned metrics (`SpendByServiceUsd`, `SpendByTagValueUsd`,
`SpendByServiceUsd`, etc.) are **not** mirrored — they're not scalars.
Query them via CloudWatch GetMetricData.

---

## 10. DynamoDB row shapes — the auditable layer

Custom metrics are useful for dashboards; the DDB tables are the
audit-grade truth. Quick reference (full schemas in each module's
`dynamodb.tf` + `docs/EDGE_CASES.md`):

| Table | PK pattern | SK pattern | Drives |
|---|---|---|---|
| `<prefix>-alerting-events` | `DEDUP#<sha>` / `AUDIT#<iso-ts>` | `STATE` | Dispatcher dedup window + permanent audit |
| `<prefix>-budgets-state` | `BUDGET#<name>` | `STATE` / `SNAPSHOT#<date>` / `ACTION#<iso-ts>` | Budget performance Lambda's daily snapshots + Budget Actions audit |
| `<prefix>-idle-findings` | `<RESOURCETYPE>#<id>` | `STATE` / `ACTION#<iso-ts>` | Per-resource lifecycle state (new/aging/snoozed/excepted/deleted) + audit log. GSI on `Status`. |
| `<prefix>-scheduler-state` | `<RESOURCETYPE>#<id>` | `STATE` / `ACTION#<iso-ts>` | Per-resource managed state + audit log. GSI on `Status` for fast "show me snoozed" |
| `<prefix>-kpi-snapshots` | `<MetricName>` | `DAY#<YYYY-MM-DD>` | KPI history feeding 7d/30d trend computation |

All tables: PAY_PER_REQUEST, CMK-encrypted, PITR ON,
`prevent_destroy = true`.

---

## 11. Lambda-runtime AWS-native metrics

In addition to the framework's custom namespaces, you have the standard
`AWS/Lambda` metrics for every framework function:

| Metric | What to look for |
|---|---|
| `Invocations` | Cadence (e.g. scheduler should fire 8 640/mo for `rate(5 minutes)`) |
| `Errors` | Steady state should be 0; alarms cover this |
| `Throttles` | Should be 0; if positive, raise `reserved_concurrent_executions` |
| `Duration` | Cold start tracking; X-Ray traces explain longer tails |
| `InitDuration` | Cold-start initialisation time |
| `IteratorAge` | n/a (no stream sources in this framework) |
| `ConcurrentExecutions` | Sanity-check headroom |

Plus the standard `AWS/SQS` metrics on every DLQ
(`ApproximateNumberOfMessagesVisible`, `ApproximateAgeOfOldestMessage`).

X-Ray traces are at the segment level: cold start, AWS API calls, DDB
operations. Use the X-Ray service map to spot integration bottlenecks
without instrumenting the code.

---

## 12. Building your own dashboards

CloudWatch widget search expressions to embed in custom dashboards:

```
# All KPI metrics
SEARCH('Namespace="FinOps/KPIs"', 'Average', 86400)

# All idle-cleanup MonthlyWasteUsd, regardless of ResourceType
SEARCH('Namespace="FinOps/IdleResources" MetricName="MonthlyWasteUsd"', 'Maximum', 86400)

# All scheduler counters (top 10 metrics by value)
SEARCH('Namespace="FinOps/InstanceScheduler"', 'Sum', 3600)

# Every Lambda error count across the framework
SEARCH('Namespace="AWS/Lambda" MetricName="Errors" FunctionName="<name_prefix>-"', 'Sum', 300)
```

The framework's own dashboards already use these patterns — see each
module's `cloudwatch.tf`.

---

## 13. Cardinality + cost-driver checklist

Per [COST_ESTIMATE.md §3.13](COST_ESTIMATE.md), CloudWatch custom
metrics cost $0.30/metric/month for the first 10 000 metrics. To
minimize:

- [ ] Set `tag_value_dashboard_tag = null` if you don't need
      per-BU widgets.
- [ ] If you do use it, pick a *bounded* allocation tag (BusinessUnit,
      CostCenter — 10–50 values). Never set it to `Owner` or
      `AccountId` (hundreds of values).
- [ ] Set `trend_metrics_enabled = false` if you don't use the
      `_7d/_30d/_WoW` derivatives. Saves ~15 metrics.
- [ ] Set `builtin_kpis_enabled.commitment_coverage = false` if
      Cloudability already owns RI/SP coverage analytics.
- [ ] Don't add a custom KPI for something already covered by a
      built-in.
- [ ] Constrain `spend_by_service` to top-10 (default) — don't expose
      every service in CUR.

The framework's defaults emit ~70 distinct metrics for a typical
production deployment. The largest variable is the cardinality of
`tag_value_dashboard_tag`.

---

## 14. References

- [COST_ESTIMATE.md](COST_ESTIMATE.md) — what each metric costs
- [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md) — how to respond to alarms
- [THREAT_MODEL.md](THREAT_MODEL.md) — what tampering protections each metric carries
- Per-module `README.md` — emitter-specific detail
- Per-module `docs/EDGE_CASES.md` — when each metric is suppressed or
  defaulted
- AWS CloudWatch pricing: aws.amazon.com/cloudwatch/pricing
