# Deployment Phases — Crawl / Walk / Run

The [FinOps Foundation](https://www.finops.org/framework/maturity-model/)
describes a maturity model with three phases. This document maps each
phase to a concrete configuration of Solidus FinOps — which enable-flags
to set, which to defer, and what to look for before moving to the next
phase.

The exit criteria are deliberately observable, not subjective.

---

## Phase 1 — Crawl

**Goal:** get cost data flowing, catch the worst budget breaches, learn
what your account actually looks like. Don't automate anything destructive.

### Configuration

| Flag | Value | Why |
|---|---|---|
| `cost_data_exports_enabled` | `true` | CUR 2.0 is the data substrate for everything else |
| `cost_data_exports_focus_enabled` | `false` | Add later when you have multi-cloud or want format choice |
| `cost_data_exports_athena_enabled` | `true` | Free; lets you query as soon as data lands |
| `cost_data_exports_health_check_enabled` | `true` | Free; alerts you if CUR stops landing |
| `tag_governance_enabled` | `false` | Wait until a taxonomy is decided |
| `idle_cleanup_enabled` | **`false`** | Don't run mutation-capable Lambdas yet |
| `instance_scheduler_enabled` | **`false`** | Same |
| `finops_metrics_enabled` | **`false`** | Athena views are useful once CUR has 1+ months of data |
| `budgets_items` | one account-level budget only | Use it as a circuit-breaker, not an allocation tool |
| `alerting_legacy_emails` | populated | Email-only at this phase is fine |
| `log_retention_days` | `90` or `365` | 7-year is overkill until you have a compliance reason |

This is the [`examples/minimal`](../examples/minimal/main.tf) shape.

### Exit criteria — move to Walk when

- ✅ CUR has been delivering for **≥ 30 days** (you can run a real month-over-month query in Athena).
- ✅ A chargeback or showback agreement exists with finance — at minimum, you've agreed what tag keys carry allocation meaning.
- ✅ Stakeholders can list the top 5 services by cost from memory.
- ✅ You've reviewed the AWS Cost Anomaly Detection inbox at least once (Cost Anomaly Detection is enabled outside the framework — in the Cost Explorer console — but its impact is visible via `AnomalyImpactUsdMtd` once you enable `finops-metrics` in Walk).

---

## Phase 2 — Walk

**Goal:** allocate spend, see KPIs as named metrics, get committed-spend
coverage right. Still no destructive automation in non-dry-run mode.

### Configuration changes from Crawl

| Flag | New value | Why |
|---|---|---|
| `cost_data_exports_focus_enabled` | `true` | You'll want format flexibility once a BI tool is involved |
| `tag_governance_enabled` | `true` | Now that allocation tags are agreed, enforce them |
| `tag_governance_required_tags` | `[CostCenter, Environment, Owner, Application, BusinessUnit, DataClassification]` | Standard FinOps tag set |
| `tag_governance_taxonomy` | populated with `level` + `purpose` per tag | Drives the untagged-cost report's mandatory list + module docs |
| `tag_governance_drift_detection_enabled` | `true` | Audit mutations of allocation-critical tag keys |
| `tag_governance_record_global_resources` | `false` if Config is enabled org-wide | Saves Config CI volume |
| `finops_metrics_enabled` | `true` | Begin emitting named KPIs to CloudWatch + SSM + DDB snapshots |
| `finops_metrics_trend_metrics_enabled` | `true` (default) | 7d / 30d moving averages + WoW drift signals start accumulating |
| `idle_cleanup_enabled` | `true` with `idle_cleanup_dry_run = true` | Get the report; don't act on it yet |
| `budgets_items` | account + 3–5 service + 2–3 tag-scoped | Detect drift per BU |
| `budgets_performance_tracking_enabled` | `true` | Daily variance + burn-rate + adherence-score Lambda |
| `alerting_slack_webhook_url` | populated | Stop having FinOps alerts go to one email inbox |
| `finops_metrics_alarm_thresholds` | defaults | Start measuring against soft targets |

### Exit criteria — move to Run when

- ✅ **Allocation coverage ≥ 80%** for 4 consecutive weeks (the `AllocationCoveragePct` CloudWatch metric, watched by the built-in alarm and the WoW-drift alarm).
- ✅ All `tag_governance_taxonomy` levels and untagged-cost report findings have been reviewed by finance.
- ✅ Idle-cleanup dry-run output has been reviewed at least twice and exception tags (`FinOpsException=true`) are placed on legitimate "looks idle, actually isn't" resources.
- ✅ Commitment coverage trends (RI + SP) have been reviewed and a purchase decision has happened (even if the decision was "not yet").
- ✅ `ForecastAbsDriftPct` has stabilised — you understand its normal noise floor.

---

## Phase 3 — Run

**Goal:** automated, continuously-improving FinOps practice with
quantitative KPIs and real cost reduction actions.

### Configuration changes from Walk

| Flag | New value | Why |
|---|---|---|
| `instance_scheduler_enabled` | `true` | Tag-driven start/stop for non-prod environments |
| `instance_scheduler_max_actions_per_tick` | tuned to your fleet size | Blast-radius cap if a mis-tag targets thousands |
| `idle_cleanup_dry_run` | **`false`** | Only after you trust the report and you've placed exception tags |
| `idle_cleanup_ebs_min_age_days` / `idle_cleanup_snapshot_min_age_days` | tuned | Tighter ages if cleanup has been clean for months; looser if false positives |
| `finops_metrics_alarm_thresholds` | tightened | E.g. `allocation_coverage_min_pct = 95`, `commitment_utilization_min_pct = 90` |
| `finops_metrics_tag_value_dashboard_tag` | `"BusinessUnit"` (or your primary allocation dim) | Auto per-BU dashboards refreshed daily |
| `finops_metrics_custom_kpis` | populated with org-specific KPIs (cost-per-transaction, etc.) | Unit-economics layer |
| `budgets_items` | account + per-service + per-BU + per-cost_category | Full multi-dimensional budgeting |
| `tag_governance_untagged_cost_report_enabled` | `true` | Weekly dollarised tag-gap report |
| `aws_secondary_regions` | populated if you operate in multiple regions | Multi-region scanning for idle-cleanup + instance-scheduler |
| `log_retention_days` | matches your compliance regime (365 / 1827 / 2557) | Now that you have something worth retaining |
| `alerting_teams_webhook_url` / `alerting_channels.pagerduty` | populated if relevant | Multi-channel notifications with severity routing |

This is the [`examples/production`](../examples/production/main.tf) shape.

### Steady-state operations

At this phase the framework runs itself. Human attention shifts from
"wire it up" to **review cadence**:

| Frequency | Activity | Source |
|---|---|---|
| Continuous | KPI drift alarms (absolute + WoW) | `finops-metrics` CloudWatch alarms → events bus → dispatcher |
| Daily | Anomaly review | Cost Explorer console + `finops-metrics` `AnomalyImpactUsdMtd` KPI |
| Daily | Budget burn-rate + adherence | `budgets` performance Lambda → dashboard |
| Weekly | Idle resource report | `idle-resource-cleanup` digest → events bus |
| Weekly | Scheduler discovery report | `instance-scheduler` weekly discovery Lambda |
| Weekly | Untagged-cost report | `tag-governance` Athena-driven dollarisation |
| Monthly | Chargeback close | DDB KPI snapshots → BI tool / Cloudability |
| Monthly | Top-mover review | Athena query `<name_prefix>-kpi-month-over-month-growth` |
| Quarterly | Tag taxonomy + required-tag list refresh | PR review against `tag_governance_required_tags` + `tag_governance_taxonomy` |
| Quarterly | Commitment renewal | `CommitmentCoveragePct` + `CommitmentUtilizationPct` trend |
| Annually | Framework module upgrade | Bump provider versions; re-run `terraform validate` + lint pipeline |

---

## Going backwards

Demoting from Run → Walk is fine. The framework supports it — flip the
flag, `terraform apply`, the destructive Lambdas turn off and KPIs stay
accurate. The only resources you can't easily remove are KMS and the
cost-data S3 bucket (deliberate — `prevent_destroy`). Edit those
lifecycle blocks intentionally if you actually need to retire the stack.

## Anti-patterns to avoid in any phase

- **Skipping straight to Run.** Idle-cleanup in non-dry-run mode without first letting it report for a month will at some point delete something someone wanted.
- **Lots of `tag_governance_required_tags` before tag compliance is real.** Each rule chunk costs Config evaluation $; tagging discipline is a people problem, not a Terraform problem.
- **Auto-remediation of missing tags.** This framework deliberately doesn't, for the reasons in [modules/tag-governance/README.md](../modules/tag-governance/README.md).
- **Treating Cost Anomaly Detection as quiet.** It needs about a month of baseline before alerts become useful.
- **Buying RIs / SPs at Crawl.** You don't yet know your steady-state workload.
- **Trusting `ForecastAbsDriftPct` in the first 3 days of a month.** The aggregator deliberately skips it; absolute-threshold alarms ignore the gap. WoW-drift KPI starts being useful around day 14.
- **Setting a dollar-denominated ceiling on `instance-scheduler`.** It doesn't have one — `instance_scheduler_max_actions_per_tick` is count-based on purpose. See the [scheduler CHANGELOG](../modules/instance-scheduler/CHANGELOG.md) for why hardcoded regional rates lie.
