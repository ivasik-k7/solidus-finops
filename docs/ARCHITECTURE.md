# Architecture — Solidus FinOps

Solidus FinOps is organized around the
[FinOps Foundation Capabilities](https://www.finops.org/framework/capabilities/).
Each module implements one or more named Capabilities; the root composition
wires them together via a shared events bus and a shared KMS CMK.

The framework ships **seven modules**. Anything in the
[FinOps Foundation framework](https://www.finops.org/framework/) that isn't
listed below is intentionally outside this codebase — see "What lives
OUTSIDE this framework" at the bottom.

## Aligning to the FinOps Foundation Framework

The Foundation groups Capabilities into six **domains**. The table below
shows which modules sit in which domain and what the framework actually
delivers for each.

| Domain | Capability | Module(s) | What this framework produces |
|---|---|---|---|
| **Understand cloud usage and cost** | Data Ingestion & Normalization | `cost-data-exports` | CUR 2.0 + FOCUS 1.0 in S3, partitioned, Athena-queryable; daily health-check Lambda |
| | Allocation | `tag-governance` | Required-tag Config rules (chunked over the 6-tag managed-rule limit), tag taxonomy as code, allocation Resource Groups |
| | Reporting & Analytics | `cost-data-exports` + `finops-metrics` | Athena workgroup; pre-built named-queries library; daily KPI aggregator → CloudWatch + SSM + DDB snapshots; auto-rebuilt dashboard with per-tag-value widgets |
| | Anomaly Management | (external) | Cost Explorer's native Cost Anomaly Detection is deliberately not modeled here — Cloudability / Cost Explorer console own this; the framework consumes its `AnomalyImpactUsdMtd` KPI in `finops-metrics` |
| **Quantify business value** | Forecasting | `budgets` | Forecasted threshold alerts via Budgets; `finops-metrics` ForecastAbsDriftPct tracks actual-vs-forecast drift |
| | Budgeting | `budgets` | Polymorphic budgets (account / service / tag / cost_category); AWS Budget Actions for auto-enforcement; daily performance Lambda (variance, burn-rate, adherence score) |
| | Benchmarking | `finops-metrics` | Named KPIs: allocation coverage, RI+SP coverage/utilization, forecast drift, anomaly impact, spend-by-service. 7d / 30d moving averages + WoW drift signals |
| | Unit Economics | `finops-metrics` `custom_kpis` | User-defined KPIs in HCL (Athena SQL → metric + DDB snapshot + optional alarm). Cost-per-transaction, cost-per-active-user, etc. |
| **Optimize cloud usage and cost** | Rate Optimization | `finops-metrics` | Tracks RI + SP commitment coverage and utilization; alarms below configurable threshold |
| | Workload Optimization | `idle-resource-cleanup` + `instance-scheduler` | Idle-resource flagging (six types) with two-phase EBS delete and DDB audit; tag-driven start/stop with action-count blast cap |
| | Architecting for Cloud | (out of scope) | Compute Optimizer + Cost Optimization Hub aren't modeled here — they're free AWS services the caller enrolls in via the AWS console or a separate workspace |
| | Cloud Sustainability | (out of scope) | AWS Customer Carbon Footprint Tool is not modeled — likely candidate for a future module |
| **Manage the FinOps practice** | Policy & Governance | `tag-governance` | Required-tag Config rules + EventBridge tag-drift detection → events bus; weekly untagged-cost dollarization Lambda |
| | FinOps Practice Operations | `alerting` (the framework itself) | The events bus + dispatcher Lambda + DLQ network + dashboards are the operational backbone every other module publishes to |
| | FinOps Education | — | Out of scope for code |
| | Onboarding Workloads | — | Out of scope; handle via IaC patterns |
| **Embed FinOps** | Chargeback & IT Finance Integration | `finops-metrics` + `tag-governance` taxonomy | KPI values in CloudWatch + SSM Parameter Store for cross-workspace consumption; tag taxonomy as code makes chargeback rules reproducible from `git log` |
| | Invoicing & Billing | — | Out of scope; downstream of allocation |
| | FinOps Tools & Services | — | The framework itself |
| | Intersecting Disciplines | — | Plug into your security / data / sustainability programs |

## Module deployment order + dependencies

The root composition deploys modules in this order. `alerting` is created
first because every other module publishes to its events topic.

```
alerting               ← root (created first; everyone reads local.events_topic_arn)
   ▲
   ├── cost-data-exports       (independent — needs kms + alerting)
   ├── tag-governance          (optionally reads cost-data-exports' Athena workgroup for the untagged-cost report)
   ├── budgets                 (independent of other modules; Budget Actions optional)
   ├── idle-resource-cleanup   (independent — needs kms + alerting + scan regions)
   ├── instance-scheduler      (independent — needs kms + alerting + scan regions)
   └── finops-metrics          (requires cost-data-exports' Athena workgroup + database)

cost-data-exports     ← depends on kms only
```

Every module is also **standalone-reusable** — none has a hard Terraform
dependency on a sibling. `events_topic_arn = null` is a valid state for the
modules that accept it (`instance-scheduler`, `finops-metrics`, the alerting
module's own threshold alarms); without it, those modules still write to
CloudWatch, SSM, and DDB, only the SNS digest is skipped.

## Data flow

```
                          ┌─────────────────────────┐
                          │   AWS Billing Service   │
                          └──────────┬──────────────┘
                                     │ writes (us-east-1)
                                     ▼
   ┌─────────────────────────────────────────────────────────────┐
   │   cost-data-exports                                         │
   │   ┌─────────────┐   ┌──────────────┐   ┌─────────────────┐ │
   │   │   CUR 2.0   │   │  FOCUS 1.0   │   │  S3 bucket      │ │
   │   │   export    │──▶│    export    │──▶│  (KMS-encrypted)│ │
   │   └─────────────┘   └──────────────┘   └────────┬────────┘ │
   │                                                  │         │
   │                          ┌───────────────────────┘         │
   │                          ▼                                 │
   │                   ┌──────────────┐                         │
   │                   │   Athena WG  │◀── Glue crawler         │
   │                   │  + database  │     + named queries     │
   │                   └──────┬───────┘                         │
   │                          │                                 │
   │            daily health-check Lambda                       │
   │   (CUR freshness + crawler success + Athena query probe)   │
   └──────────────────────────┼─────────────────────────────────┘
                              │ queried by
                              ▼
       ┌──────────────────────────────────────────────────┐
       │  finops-metrics                                  │
       │  - daily KPI aggregator Lambda                   │
       │  - DDB snapshots (one row / KPI / day, 400d TTL) │
       │  - CloudWatch metrics under FinOps/KPIs          │
       │  - SSM Parameter mirror (scalar KPIs)            │
       │  - dashboard re-PUT every run (trends, custom    │
       │    KPIs, per-tag-value widgets)                  │
       └──────────────────────────────────────────────────┘
                              ▲                            ▲
                              │ joins (untagged-cost)      │ optional consumers
                              │                            │
   ┌──────────────────────────┴───────────────┐            │
   │  tag-governance                          │            │
   │  - Config rules + EventBridge drift      │            │
   │  - weekly untagged-cost Lambda           │            │
   │  - allocation Resource Groups            │            │
   └──────────────────────────────────────────┘            │
                                                           │
   ┌─────────────────────────────────────────────────────────────────┐
   │            Events bus (SNS, KMS-encrypted)                       │
   │                                                                  │
   │   ┌────────────┐                                                 │
   │   │            │───▶ Email subscribers                           │
   │   │ SNS topic  │                                                 │
   │   │  (CMK)     │───▶ ┌─────────────────────────────┐             │
   │   │            │     │ Dispatcher Lambda           │──▶ Slack    │
   │   └─────▲──────┘     │ (multi-channel, severity-   │──▶ Teams    │
   │         │            │  routed, dedup, audit log,  │──▶ PagerDuty│
   │         │            │  Secrets Manager-backed)    │──▶ Opsgenie │
   │         │            └─────────────────────────────┘──▶ webhooks │
   │         │                                                        │
   └─────────┼────────────────────────────────────────────────────────┘
             │ publishes
             │
   ┌─────────┴──────┬─────────────────┬──────────────────┐
   │                │                 │                  │
   ▼                ▼                 ▼                  ▼
 Budgets    Tag Governance     Idle Cleanup       Instance Scheduler
 - thresh   - non-compl        - 6 types          - tag-driven start/stop
 - actions  - drift            - DDB STATE+ACTION - DDB STATE+ACTION+GSI
 - perf KPI - untagged-cost    - aging escalation - action-count blast cap
   (DLQ +     digest             two-phase EBS      multi-region scan
   alarms)                       delete (snap 1st)  per-region isolation
```

## Audit pattern (used by every action-taking module)

Each module that mutates AWS state writes two row types to its own DDB
table (`<prefix>-<module>-state` or `-findings` or `-snapshots`):

| Row | Key shape | Purpose |
|---|---|---|
| **STATE** | `PK = "<ResourceType>#<ResourceId>"`, `SK = "STATE"` | One row per resource. Current state, last-seen, owner. TTL ~90 days. |
| **ACTION** | `PK = "<ResourceType>#<ResourceId>"`, `SK = "ACTION#<iso-ts>-<uuid>"` | Append-only audit log. One row per action (start / stop / delete / skip / failure). TTL ~7 years for regulatory workloads. |

`instance-scheduler` adds a GSI keyed by date for cheap "what happened on
2026-05-29?" queries. `finops-metrics` uses a simpler schema: `PK =
"KPI#<MetricName>"`, `SK = "<YYYY-MM-DD>"`.

## What lives OUTSIDE this framework

By design, the framework does NOT include:

- **A FinOps dashboard or BI tool.** Output is structured data (CUR, KPI
  Athena views, CloudWatch metrics, SSM parameters, DDB audit rows). Plug
  it into QuickSight, Power BI, Looker, Tableau, or Cloudability.
- **Anything that touches production data without explicit opt-in.**
  Idle cleanup is dry-run by default. Instance scheduler is opt-in by tag.
- **Tag remediation that mutates resources.** AWS Config could be
  configured to auto-tag; the framework deliberately doesn't, for reasons
  documented in
  [modules/tag-governance/README.md](../modules/tag-governance/README.md).
- **Cost Anomaly Detection wiring.** Cost Explorer console + Cloudability
  own anomaly *detection*. The framework consumes the
  `AnomalyImpactUsdMtd` KPI in `finops-metrics` and emits absolute-impact
  + WoW-drift alarms on it.
- **Multi-account / org-management primitives.** SCPs, Tag Policies, and
  payer-account roll-up are out of scope — handle those in your
  landing-zone / org-management workspace.
- **A hardcoded regional rate table.** Dollar-value reporting is owned by
  the analytics layer (Cloudability / CUR-backed dashboards). The framework
  emits action counts and DDB audit rows; pricing joins happen where
  prices actually live.

## Failure modes and how the framework handles them

| Failure | Behaviour |
|---|---|
| CUR delivery fails | S3 bucket policy logs the rejection; no impact on other modules. The daily health-check Lambda detects this and publishes a high-severity event with the freshness gap. |
| SNS delivery fails | Subscriptions retry per AWS defaults. The dispatcher Lambda has its own DLQ; failed sends land there with the full event for replay. |
| Lambda execution fails | Exception logs to CloudWatch (CMK-encrypted, configurable retention). Failed async invocations land in the per-Lambda SQS DLQ (14-day retention). Two CloudWatch alarms fire to the events topic: `Lambda Errors` and `DLQ ApproximateNumberOfMessagesVisible`. |
| Per-resource failure inside a scan | Each scanning Lambda (idle-cleanup, instance-scheduler) wraps every resource in `try/except`. One bad resource doesn't poison the tick; the failure is recorded as an ACTION row with `failed` status. |
| One region in a multi-region scan fails | Each region's iteration is wrapped in `try/except`. Other regions continue. The failed region's error is recorded in the run's `errors[]` list, the Lambda raises at end-of-run so the DLQ catches a copy. |
| KMS key rotation | The framework's CMK has automatic rotation enabled. No action needed. |
| Cost Explorer API throttling | `finops-metrics` per-KPI `try/except` isolates the throttled call; other KPIs publish. The throttled KPI re-runs next day. |
| Athena query failures | Per-KPI `try/except`; failed queries logged + recorded in `errors[]`, the Lambda raises at end so the DLQ catches a copy. |
| `finops-metrics` aggregator fails entirely | Lambda alarm fires; KPI values in CloudWatch + SSM + DDB go stale until next successful run. Last-known-good values remain readable. |
| Dashboard widget body drift | Modules whose Lambda re-PUTs the dashboard (`finops-metrics`) use `ignore_changes = [dashboard_body]` so the daily refresh doesn't show up as TF plan noise. |
