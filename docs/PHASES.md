# Deployment Phases — Crawl / Walk / Run

The [FinOps Foundation](https://www.finops.org/framework/maturity-model/) describes a maturity model with three phases. This document maps each phase to a concrete configuration of this framework — which enable-flags to set, which to defer, and what to look for before moving to the next phase.

The exit criteria are deliberately observable, not subjective.

---

## Phase 1 — Crawl

**Goal:** get cost data flowing, catch the worst anomalies, learn what your account actually looks like. Don't automate anything destructive.

### Configuration

| Flag | Value | Why |
|---|---|---|
| `enable_cost_data_exports` | `true` | CUR 2.0 is the data substrate for everything else |
| `enable_focus_export` | `false` | Add later when you have multi-cloud or want format choice |
| `enable_athena_workgroup` | `true` | Free; lets you query as soon as data lands |
| `enable_anomaly_detection` | `true` | Free; threshold high enough to avoid noise (`anomaly_min_impact_amount = 100` minimum) |
| `enable_compute_optimizer` | `true` | Free; surfaces rightsizing immediately |
| `enable_cost_optimization_hub` | `true` | Free |
| `enable_idle_cleanup` | **`false`** | Don't run mutation-capable Lambdas yet |
| `enable_instance_scheduler` | **`false`** | Same |
| `enable_savings_coverage_reporter` | `false` | Wait until your RI/SP footprint is non-trivial |
| `enable_finops_metrics` | **`false`** | Athena views are useful once CUR has 1+ months of data |
| `budgets` | one account-level budget only | Use it as a circuit-breaker, not an allocation tool |
| `required_tags` | minimal (CostCenter, Environment, Owner) | Bigger lists trigger more Config rules to start |
| `tag_governance_record_global_resources` | `false` | Saves Config CI volume |
| `log_retention_days` | `90` or `365` | 7-year is overkill until you have a compliance reason |

This is the [`examples/minimal`](../examples/minimal/main.tf) shape.

### Exit criteria — move to Walk when

- ✅ CUR has been delivering for **≥ 30 days** (you can run a real month-over-month query).
- ✅ Tag compliance is **≥ 50%** by resource count (run the `<name_prefix>-kpi-allocation-coverage` query manually).
- ✅ You've reviewed the anomaly inbox at least once and tuned `anomaly_min_impact_amount` to a non-noisy level.
- ✅ A chargeback or showback agreement exists with finance — at minimum, you've agreed what tag keys carry allocation meaning.
- ✅ Stakeholders can list the top 5 services by cost from memory.

---

## Phase 2 — Walk

**Goal:** allocate spend, see KPIs as named metrics, get committed-spend coverage right. Still no destructive automation in non-dry-run mode.

### Configuration changes from Crawl

| Flag | New value | Why |
|---|---|---|
| `enable_focus_export` | `true` | You'll want format flexibility once a BI tool is involved |
| `enable_savings_coverage_reporter` | `true` | Track RI/SP coverage actively |
| `enable_finops_metrics` | `true` | Begin emitting named KPIs to CloudWatch + SSM |
| `enable_idle_cleanup` | `true` with `idle_cleanup_dry_run = true` | Get the report; don't act on it yet |
| `cost_categories` | populated for BusinessUnit (or your primary allocation dimension) | The single most-valuable artifact for chargeback |
| `budgets` | account + 3–5 service + 2–3 tag-scoped | Detect drift per BU |
| `required_tags` | expand to CostCenter + Environment + Owner + Application + BusinessUnit + DataClassification | Standard FinOps tag set |
| `notification_emails` + `slack_webhook_url` | populated | Stop having FinOps alerts go to one inbox |
| `finops_metrics_alarm_thresholds` | defaults | Start measuring against soft targets |

### Exit criteria — move to Run when

- ✅ **Allocation coverage ≥ 80%** for 4 consecutive weeks (the `AllocationCoveragePct` CloudWatch metric).
- ✅ All `cost_category` rules have been reviewed by finance.
- ✅ Idle-cleanup dry-run output has been reviewed at least twice and exception tags are placed on legitimate "looks idle, actually isn't" resources.
- ✅ The savings-coverage report has been reviewed and a commitment-purchase decision has happened (even if the decision was "not yet").
- ✅ Forecast drift KPI is being watched — even if it's noisy.

---

## Phase 3 — Run

**Goal:** Automated, continuously-improving FinOps practice with quantitative KPIs and real cost reduction actions.

### Configuration changes from Walk

| Flag | New value | Why |
|---|---|---|
| `enable_instance_scheduler` | `true` | Tag-driven start/stop for non-prod environments |
| `idle_cleanup_dry_run` | **`false`** | Only after you trust the report and you've placed exception tags |
| `idle_cleanup_*_min_age_days` | tuned | Tighter ages if cleanup has been clean for months; looser if false positives |
| `finops_metrics_alarm_thresholds` | tightened | E.g. `allocation_coverage_min_pct = 95`, `commitment_utilization_min_pct = 90` |
| `budgets` | account + per-service + per-BU + per-cost_category | Full multi-dimensional budgeting |
| `cost_categories` | multi-dimensional (BU + Regulatory + Environment + Product) | Production-grade allocation |
| `log_retention_days` | matches your compliance regime (365 / 1827 / 2557) | Now that you have something worth retaining |
| `teams_webhook_url` | populated if relevant | Multi-channel notifications |

This is the [`examples/production`](../examples/production/main.tf) shape.

### Steady-state operations

At this phase the framework runs itself. Human attention shifts from "wire it up" to **review cadence**:

| Frequency | Activity | Source |
|---|---|---|
| Continuous | KPI drift alarms | `finops-metrics` CloudWatch alarms → events bus |
| Daily | Anomaly review | `anomaly-detection` → events bus |
| Weekly | Idle resource report | `idle-resource-cleanup` |
| Weekly | RI/SP coverage report | `savings-coverage-reporter` |
| Monthly | Chargeback close | Athena query: `<name_prefix>-kpi-unit-cost-by-business-unit` |
| Monthly | Top-mover review | Athena query: `<name_prefix>-kpi-month-over-month-growth` |
| Quarterly | Tag-rule and Cost Category refresh | PR review against `var.required_tags` + `var.cost_categories` |
| Quarterly | Commitment renewal | savings-coverage report deltas |
| Annually | Framework module upgrade | Bump provider versions; re-run [.github/workflows/terraform-ci.yml](../.github/workflows/terraform-ci.yml) |

---

## Going backwards

Demoting from Run → Walk is fine. The framework supports it — flip the flag, `terraform apply`, the destructive Lambdas turn off and KPIs stay accurate. The only resources you can't easily remove are KMS and the cost-data S3 bucket (deliberate — `prevent_destroy`). Edit those lifecycle blocks intentionally if you actually need to retire the stack.

## Anti-patterns to avoid in any phase

- **Skipping straight to Run.** Idle-cleanup in non-dry-run mode without first letting it report for a month will at some point delete something someone wanted.
- **Lots of required_tags before tag compliance is real.** Each rule chunk costs Config evaluation $; tagging discipline is a people problem not a Terraform problem.
- **Auto-remediation of missing tags.** This framework deliberately doesn't, for the reasons in [modules/tag-governance/README.md](../modules/tag-governance/README.md).
- **Treating Cost Anomaly Detection as quiet.** It needs about a month of baseline before alerts become useful.
- **Buying RIs / SPs at Crawl.** You don't yet know your steady-state workload.
