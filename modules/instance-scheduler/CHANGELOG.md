# Changelog

All notable changes to the `instance-scheduler` module are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

Module versions are independent of the parent FinOps framework — pin the
module ref explicitly when consuming it as a standalone module.

## [Unreleased]

### Changed — BREAKING

- **Removed rate / savings estimation from the module entirely.** Hourly
  rate tables are wrong on day one: regional pricing varies by 50%+,
  AWS adjusts prices over time, and any hardcoded table ignores RIs /
  SPs / EDP discounts. Dollar-value reporting belongs in the analytics
  layer (Cloudability / CUR), which joins resource activity to actual
  paid prices. The module now emits action counts; the analytics layer
  answers "how much did we save?"

#### Removed

- `var.cost_ceiling_usd_per_tick` — replaced by `var.max_actions_per_tick`
- `var.instance_rates_usd_hourly` — see rationale above
- `var.unknown_rate_usd_hourly` — see rationale above
- `aws_ssm_parameter.instance_rates` (entire `ssm.tf`) — no longer needed
- `ssm:GetParameter` permission on the scheduler role
- `SavingsUsd` CloudWatch metric (per ResourceType)
- "Cumulative monthly savings (USD)" dashboard widget — replaced by
  "Daily action throughput"
- `EstimatedSavingsUsd` attribute on DDB `ACTION` rows
- `_load_instance_rates()`, `_rate_for()`, `_aurora_cluster_rate()` from
  scheduler.py

#### Added

- `var.max_actions_per_tick` (default 200) — count-based blast-radius
  cap. Replaces the dollar-denominated ceiling.

#### Migration

Callers on v1.0 must replace `cost_ceiling_usd_per_tick = N` with
`max_actions_per_tick = M` (rough rule of thumb: N/$5 → M, then tune).
Drop any `instance_rates_usd_hourly` / `unknown_rate_usd_hourly`
overrides. Cost analytics moves to your CUR/Cloudability layer.

## [1.0.0] — 2026-05-29

Initial release. Standalone-reusable tag-driven start/stop module for
AWS EC2, RDS, and Auto Scaling Groups.

### Added

- **Multi-resource scheduling** — EC2 instances, RDS DB instances, RDS DB
  clusters (Aurora), and Auto Scaling Groups (scale-to-zero with capacity
  stashed in `FinOpsSavedMin` / `FinOpsSavedDesired` tags). Each resource
  type can be toggled independently via `enable_ec2` / `enable_rds_instances`
  / `enable_rds_clusters` / `enable_asg`.
- **Tag-driven opt-in** — resources are opted in by carrying the
  `Schedule=<name>` tag. Schedule shape: `{days, start, stop, timezone}`.
- **Override tags** — `ScheduleOverrideUntil=<iso-ts>` for temporary
  bypass, `FinOpsException=true` for permanent bypass.
- **Multi-region scanning** — `scan_regions` list; per-region failures
  isolated so one bad region can't fail the whole tick.
- **Cost ceiling** — `cost_ceiling_usd_per_tick` caps how much $/hr of
  resources the scheduler will act on in a single tick. Skipped resources
  recorded as `ActionSkippedCeiling`.
- **DDB audit table** — single-table STATE + ACTION rows with TTLs at
  the right granularity (90d state, 7y action). KMS-encrypted, PITR
  enabled, `prevent_destroy = true`.
- **GSI `ActionsByDate`** — date-keyed action queries (`GSI1PK =
  ACTION#YYYY-MM-DD`). Eliminates table scans for fleet-wide history.
- **CloudWatch metrics** in namespace `FinOps/InstanceScheduler` —
  `ActionStarted`, `ActionStopped`, `ActionSkippedOverride`,
  `ActionSkippedCeiling`, `ActionSkippedSpot`, `ActionScaleAmbiguous`,
  `ActionFailed`, `ManagedResourceCount`, `SavingsUsd`,
  `DiscoveryCandidateCount`.
- **Auto-provisioned dashboard** — savings curve, activity per tick,
  managed resource counts, errors + DLQ depth.
- **Alarms** — Lambda errors, DLQ depth, discovery errors. Optionally
  wired to `events_topic_arn`.
- **Auto-discovery Lambda** — weekly scan for low-CPU resources lacking
  the opt-in tag; publishes candidate proposals (advisory only, never
  modifies resources).
- **Standalone mode** — `events_topic_arn` is optional. Without it,
  metrics + DDB + dashboard still work; SNS publishes are skipped.
- **Spot instance handling** — EC2 spot detection via `InstanceLifecycle`;
  skipped by default with `ActionSkippedSpot` metric. Opt-in via
  `enable_spot_management = true`.
- **Transient-state handling** — EC2 (`terminated` / `shutting-down` /
  `stopping`) and RDS (`modifying` / `backing-up` / `creating` / `deleting`
  / etc) skipped cleanly. Aurora cluster members skipped at the instance
  level (cluster owns them). Aurora Serverless skipped (start/stop
  unsupported).
- **Per-resource failure isolation** — `try/except` around every resource
  loop iteration. One bad resource cannot poison the tick.
- **ASG stash-miss detection** — if `FinOpsSavedMin`/`FinOpsSavedDesired`
  tags are missing on scale-up, falls back to 1/1 and emits
  `ActionScaleAmbiguous` metric.
- **Module file structure** — split by concern across 11 .tf files
  (`versions.tf` / `variables.tf` / `outputs.tf` / `locals.tf` / `data.tf`
  / `iam.tf` / `dynamodb.tf` / `sqs.tf` / `lambda.tf` /
  `eventbridge.tf` / `cloudwatch.tf`).
- **Operational tooling** — [scripts/emergency-start-all.sh](scripts/emergency-start-all.sh)
  for scheduler-outage recovery; supports `DRY_RUN=true` and
  `FILTER_REGION=<region>`.
- **Edge-cases doc** — [docs/EDGE_CASES.md](docs/EDGE_CASES.md) catalogues
  every transitional state, override semantic, region-failure mode, and
  lifecycle subtlety the module handles.

### Module contract

- Required inputs: `name_prefix`, `kms_key_arn`, `schedules`.
- Optional but recommended: `events_topic_arn`, `scan_regions`,
  `cost_ceiling_usd_per_tick`.
- Outputs: `lambda_arn`, `dlq_arn`, `state_table_name`, `state_table_arn`,
  `dashboard_name`, `dashboard_url`, `metric_namespace`, `scan_regions`,
  `schedules_configured`, `tag_keys`.
