# Changelog

All notable changes to the `finops-metrics` module are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

Module versions are independent of the parent FinOps framework — pin the
module ref explicitly when consuming it as a standalone module.

## [Unreleased]

## [1.0.0] — 2026-05-29

Initial release. Standalone-reusable FinOps KPI aggregator with daily
snapshots, trend math, per-tag-value dashboards, and user-defined custom
KPIs.

### Added

- **Module file structure** — split by concern across 12 .tf files
  (`versions.tf` / `variables.tf` / `outputs.tf` / `locals.tf` / `data.tf`
  / `iam.tf` / `dynamodb.tf` / `sqs.tf` / `athena.tf` / `lambda.tf` /
  `eventbridge.tf` / `cloudwatch.tf`).
- **Standalone mode** — `events_topic_arn` is optional. Without it,
  metrics + DDB snapshots + SSM + dashboard still work; SNS digest is
  skipped and alarms have empty `alarm_actions`.
- **Per-KPI on/off toggles** via `builtin_kpis_enabled` map. Turn off
  any built-in KPI a downstream tool (e.g. Cloudability) already covers.
- **User-defined custom KPIs** — `var.custom_kpis` accepts a map of
  Athena queries. Each becomes a Terraform-managed named query AND is
  executed by the aggregator, emitted as `Custom_<key>` metric, written
  to a DDB snapshot, and (optionally) alarmed on.
- **DDB snapshot history** — `<prefix>-kpi-snapshots` table holds one
  row per KPI per day (`PK="KPI#<name>"`, `SK="<YYYY-MM-DD>"`).
  Retention configurable via `snapshot_retention_days` (default 400d).
- **Trend metrics** — when `trend_metrics_enabled = true`, the
  aggregator reads DDB history and emits `<Metric>_7dAvg`,
  `<Metric>_30dAvg`, and `<Metric>_WoWDriftPct` alongside each base KPI.
  Unlocks week-over-week alarms without external trend analysis.
- **Week-over-week drift alarm** — fires when AllocationCoveragePct
  drops > `wow_drift_alarm_threshold_pct` % WoW. Catches tagging
  regression that absolute-threshold alarms miss.
- **Per-tag-value dashboard** — set `tag_value_dashboard_tag` (e.g.
  `BusinessUnit`) and the aggregator auto-discovers distinct values
  from CUR, emits `SpendByTagValueUsd` per value, and rebuilds the
  dashboard with one widget per top-N value. Refreshed every daily run.
- **Auto-rebuilt CloudWatch dashboard** — Terraform creates the initial
  skeleton; the Lambda re-PUTs on every run with trend lines + custom
  KPIs + per-tag-value widgets. `ignore_changes = [dashboard_body]`
  prevents drift noise in CI.
- **Custom-KPI alarms** — declare `alarm = { comparison, threshold }`
  inside a custom KPI entry and an alarm is auto-provisioned.
- **Hardened Lambda runtime** — per-KPI `try/except` isolation,
  modern `datetime.now(timezone.utc)` API, Athena pagination, adaptive
  boto3 retries, idempotent same-day re-run, day 1–3 forecast skip.
- **Edge-cases doc** — [docs/EDGE_CASES.md](docs/EDGE_CASES.md)
  catalogues new-account conditions, CUR/Cost-Explorer quirks,
  custom-KPI semantics, dashboard ownership drift, and TF lifecycle.

### Module contract

- Required inputs: `name_prefix`, `kms_key_arn`, `athena_workgroup_name`,
  `athena_database_name`.
- Optional but recommended: `events_topic_arn`, `tag_value_dashboard_tag`,
  `custom_kpis`.
- Outputs: `aggregator_lambda_arn`, `dlq_arn`, `metric_namespace`,
  `ssm_prefix`, `snapshot_table_name`, `snapshot_table_arn`,
  `dashboard_name`, `dashboard_url`, `named_query_ids`,
  `enabled_kpis`, `custom_kpi_metric_names`.
