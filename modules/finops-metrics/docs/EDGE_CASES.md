# finops-metrics — edge cases & how the module handles them

This module joins data from three independent AWS systems (CUR via Athena,
Cost Explorer, the framework's DDB history) and emits to four sinks
(CloudWatch metrics, SSM, DDB, optional SNS). Every paragraph below is a
real-world condition someone will eventually hit. Each names the cause,
the module's behavior, and the lever you have if you want different.

---

## 1. First-day / new-account conditions

### 1.1 No CUR data yet
After enabling `cost-data-exports`, the CUR crawler typically takes
24–48h to produce the first partition. Until then, Athena queries
return zero rows. The aggregator returns `None` for affected KPIs
(allocation_coverage, spend_by_service, custom KPIs over CUR) — they
are skipped with an INFO log, no metric or DDB row written. **Not an
error**: re-runs on subsequent days pick up data automatically.

### 1.2 Cost Explorer not yet enabled on the account
`ce:GetCostAndUsage` returns an authorization error. The corresponding
KPI is recorded in `errors[]`, the aggregator continues with the rest,
and the invocation ends with `RuntimeError` so the DLQ catches a copy
for ops. Other (non-CE) KPIs still publish.

### 1.3 No RIs or Savings Plans purchased
`CommitmentCoveragePct` returns 0; `CommitmentUtilizationPct` returns
`None` (both ratios are 0/0). The 0% coverage value IS published — that's
a real signal ("you have no commitments"). The `None` utilization is
correctly suppressed so a zero doesn't look like an alarm.

### 1.4 Day 1–3 of the month — forecast unreliable
`ForecastAbsDriftPct` is deliberately **skipped** during the first 3 days
of a month — the proportional MTD-vs-projected math is too noisy with
only a few days of data. The KPI resumes on day 4. The CloudWatch alarm
uses `treat_missing_data = "ignore"`, so no false-positive ALARM fires
during the skip window.

---

## 2. Athena / CUR query semantics

### 2.1 Custom KPI SQL is malformed
Athena raises `FAILED` with the parser's reason in `StateChangeReason`.
The aggregator catches it, logs the reason, appends to `errors[]`, and
continues with the next KPI. The Custom_<key> metric simply doesn't emit
this run.

### 2.2 Custom KPI returns multi-row / multi-column result
Aggregator reads only `rows[1][0]` (the first cell of the first data
row). Multi-row results are not aggregated — define your SQL with an
appropriate `SUM`/`AVG`/`MAX` so it returns a single scalar. A WARN log
flags non-numeric values as `skipped`.

### 2.3 Custom KPI returns non-numeric value
`float()` raises `ValueError`; the value is skipped with a WARN log, no
metric emitted. To emit string-shaped business KPIs use a custom Lambda
or a Cost Category — this module is numeric-only by design.

### 2.4 Athena query times out (> 180s)
The aggregator's per-query timeout is `ATHENA_MAX_WAIT_SECONDS = 180`.
Beyond that it raises `TimeoutError`, captured into `errors[]`. Tune by
splitting the query or partitioning by date. CUR partition pruning
(filtering by `billing_period`) is the single biggest optimisation.

### 2.5 Athena result paginated > 1000 rows
`_run_athena` paginates with `NextToken` until exhausted. For very wide
result sets (e.g. ~10k distinct tag values), this can be slow. The
SpendByTagValueUsd metric pre-filters via `ORDER BY ... LIMIT` if you
hit that scale — adjust the Athena query in the Lambda.

---

## 3. DynamoDB snapshot table

### 3.1 Same-day re-run
`PUT` against `(PK="KPI#X", SK="<today>")` overwrites the existing row.
**Idempotent by design** — a re-run on the same day produces the same
final state regardless of how many times it runs.

### 3.2 First run — no history yet
Trend metrics (`_7dAvg`, `_30dAvg`, `_WoWDriftPct`) require at least 2
data points to emit; on the first day they emit nothing. By day 2 you
get partial 7d-avg (over 2 points). True 7d/30d windows take 7/30 days
to build out. WoW drift needs 14+ days of history before becoming
meaningful.

### 3.3 Snapshot TTL'd before history window
Default `snapshot_retention_days = 400` keeps a full year + slack so
year-over-year comparison stays viable. Drop below 35 and the variable
validation rejects it (need at least a 30d window for moving averages).

### 3.4 KPI renamed mid-stream
DDB partition keys are stable strings. Renaming a metric means a new
`PK`; the old history is orphaned but TTL'd on schedule (no manual
cleanup required). Trend metrics start fresh.

---

## 4. Cost Explorer quirks

### 4.1 `GetCostForecast` rejects current date
AWS rejects forecasts that start in the past. When `today >= next_month`
(month boundary), `_forecast_drift` returns `None`. Picked up next day.

### 4.2 `GetAnomalies` returns paginated results
Single page only — the aggregator reads `Anomalies[]` and sums
`Impact.TotalImpact`. For accounts with > 100 anomalies in a single
month (extreme), AWS returns a `NextToken` the current code doesn't
follow. Not a real concern: 100+ confirmed anomalies in a month
indicates a deeper FinOps issue than this metric.

### 4.3 Cost Explorer throttling
`boto3` is configured with `Config(retries={"max_attempts": 10,
"mode": "adaptive"})`. Persistent throttling raises through to
`errors[]`; the invocation re-runs the next day. Cost Explorer's API
limits are generous for daily aggregations.

---

## 5. Tag-value dashboard

### 5.1 `tag_value_dashboard_tag` set but tag has no values yet
The discovery query returns zero rows. Aggregator emits no
`SpendByTagValueUsd` metrics, the dashboard's tag-value widget renders
empty but valid. Resolves automatically as tagging adoption grows.

### 5.2 Hundreds of distinct tag values
The aggregator emits a metric per value (no cap on emission) but only
renders `tag_value_dashboard_top_n` (default 12) on the dashboard.
CloudWatch retains all metrics for 15 months regardless — query the
namespace directly if you need the long-tail.

### 5.3 Tag values containing CloudWatch-reserved chars
CloudWatch dimensions accept any UTF-8 except a few control chars. Some
tag values (especially auto-generated ones with `:`/`/`) might be
truncated in the metric explorer UI but stored intact. Not a data-loss
issue.

---

## 6. Custom KPIs

### 6.1 Custom KPI metric name collision with a built-in
The custom KPI metric is prefixed `Custom_<key>` to prevent collision.
The Athena named-query name is prefixed `<name_prefix>-kpi-custom-<key>`.
Both spaces are isolated from the built-in KPIs.

### 6.2 Custom KPI alarm comparison invalid
Variable-level validation rejects anything outside `{GreaterThan,
GreaterThanOrEqualTo, LessThan, LessThanOrEqualTo}`. `terraform plan`
fails with a clear message; the alarm is never created.

### 6.3 Custom KPI key clashes with Terraform-reserved chars
Variable-level validation enforces `^[a-z][a-z0-9_]{1,48}$`. Hyphens,
spaces, uppercase, or starting digits are rejected at plan time.

---

## 7. Dashboard ownership (Terraform + Lambda)

### 7.1 Drift between Terraform and Lambda
Terraform creates the initial skeleton; the Lambda re-PUTs on every
daily run with the full layout. After the first Lambda run, the
dashboard body in AWS differs from what Terraform's plan would
produce. The TF resource has `lifecycle { ignore_changes =
[dashboard_body] }` so this drift is invisible to `terraform plan`.

If you ever want the Terraform skeleton back, `terraform apply -replace
'module.X.aws_cloudwatch_dashboard.kpis'` recreates it; the next Lambda
run restores the rich layout.

### 7.2 Dashboard widget count limit
CloudWatch caps dashboards at 500 widgets. This module emits at most
~30 widgets even with the maximum tag-value top-N. No risk of breaching
the cap.

---

## 8. Standalone mode (events_topic_arn = null)

### 8.1 What still works
- All CloudWatch metrics
- All SSM parameters
- All DDB snapshots + trend math
- The full dashboard
- Every alarm — they just have empty `alarm_actions` (CloudWatch still
  marks state as ALARM/OK, just no SNS publish)

### 8.2 What stops
- The daily SNS digest
- Alarm SNS publishes
- The IAM policy doesn't include `sns:Publish`

### 8.3 Transition from standalone to events-wired
Setting `events_topic_arn = <arn>` later is a clean diff: the IAM policy
gains a statement, the alarms gain actions, the Lambda env var gains a
value. No state migration; the next aggregator run publishes its digest.

---

## 9. Operational / TF lifecycle

### 9.1 Renaming `name_prefix`
Forces replacement of nearly everything (Lambda, DDB, IAM, alarms,
dashboard, named queries). Snapshots in the old DDB table are lost when
the table is deleted. Plan deliberately; use `moved {}` blocks where
possible.

### 9.2 Re-running the aggregator manually
Invoke the Lambda directly to backfill or test:
```
aws lambda invoke --function-name <prefix>-kpi-aggregator /tmp/out.json
```
Same-day re-run is idempotent. To backfill historical days, write a
small helper that injects `event = {"backfill_date": "YYYY-MM-DD"}` —
the current code doesn't read it, so use it as a hook for future work.

### 9.3 `terraform destroy`
The snapshot DDB table has NO `prevent_destroy`. Snapshots are derived
data and can be rebuilt by re-running the aggregator for the desired
range. Cost data exports (CUR) keep the original source unchanged.
