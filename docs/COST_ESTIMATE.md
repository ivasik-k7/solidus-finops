# Cost Estimate — Solidus FinOps Deployment

**As-of date:** 2026-05-31
**Region (primary):** `eu-central-1` (Frankfurt). Notes flag where US regions differ materially.
**Currency:** USD
**Source:** AWS public on-demand list pricing. Enterprise Discount Program (EDP) and private pricing can reduce these by 5–25%.

---

## 1. TL;DR

| Scenario | Resources in account | AWS Config recorder | **Monthly total** |
|---|---|---|---|
| Sandbox (`examples/minimal`, Config off, Lambdas off) | ~200 | off | **~$5** |
| Sandbox with Config recorder on | ~200 | on | **~$25** |
| Small production, single region | ~2 000 | on | **~$120** |
| Small production, primary + 1 secondary region | ~2 000 | on | **~$140** |
| Mid-size production account | ~10 000 | on | **~$840** |
| Mid-size, Config already org-managed | ~10 000 | off (rules only) | **~$310** |
| Large enterprise account | ~50 000 | on | **~$2 350** |
| Large enterprise, Config already org-managed | ~50 000 | off (rules only) | **~$980** |

The framework's own moving parts cost **~$45 / month** at production scale regardless of account size — KMS + Budgets + Cost Explorer + DDB + Lambda (free-tier) + **CloudWatch custom metrics** + dashboards + alarms. **AWS Config is the dominant variable** and depends on how many resources the account holds and how often they change. If Config recording is already enabled at the organization level (typical with AWS Control Tower), the `tag-governance` module re-uses it and you save 60–80% of the total framework cost.

> **What changed since v0.1.0?**  v0.2.1 added X-Ray Active tracing on every Lambda, expanded the custom-metric surface (per-tag-value SpendByTagValueUsd, 7d/30d/WoW trends), and added the burn-rate metric-math alarm in `budgets`. Net impact on the framework baseline: **~$30/month more** than the v0.1.0 estimate, almost entirely from CloudWatch custom metrics that were previously missing from this document.

---

## 2. What the framework provisions (cost-relevant inventory)

| AWS service | Resources created | Notes |
|---|---|---|
| KMS | 1 customer-managed key + 1 alias | Used by every other component |
| Secrets Manager | 0–N secrets | One per inline-supplied chat webhook / PD-key / Opsgenie-key |
| AWS Budgets | 1–10+ budgets | Driven by `var.budgets_items` map |
| AWS Cost & Usage Report 2.0 | 1 export (BCM Data Exports) | **Free delivery**; pay only for S3 storage |
| BCM Data Exports (FOCUS 1.0) | 1 export | **Free delivery** |
| S3 | 3 buckets (cost-data, athena-results, config) | KMS-encrypted, lifecycle managed |
| Athena workgroup + Glue DB + crawler | 1 each + Glue security configuration | Per-query cost only |
| AWS Config | 1 recorder + N rule chunks + 1 delivery channel | The expensive line |
| EventBridge | ~9 rules | Scheduling + Config compliance + tag-drift + crawler-state |
| SNS | 1 topic | Plus N email + 1 dispatcher Lambda subscription |
| Lambda (with X-Ray Active tracing) | 13 functions | All within free tier in practice |
| SQS | One DLQ per Lambda | SSE-SQS managed encryption (free) |
| CloudWatch Logs | 13 log groups | Configurable retention (default 365 d) |
| CloudWatch Custom Metrics | ~80 distinct metrics across 5 namespaces | First 10 000 @ $0.30/metric/mo |
| CloudWatch Alarms | ~24 alarms | Most paid (free tier covers 10) |
| CloudWatch Dashboards | 5 auto-provisioned dashboards | First 3 free, then $3/mo each |
| DynamoDB | 5 tables (alerting events, budgets state, idle findings, scheduler state, KPI snapshots) | All PAY_PER_REQUEST + CMK + PITR |
| X-Ray | Active tracing on all 13 Lambdas | $5/1M traces recorded |
| IAM | One role per Lambda + cross-account reader roles per `cross_account_readers` entry | No cost |

---

## 3. Per-service cost breakdown

All numbers below are **monthly**, in USD, at `eu-central-1` list pricing.

### 3.1 KMS

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Customer-managed key | $1.00 / CMK / mo | 1 | **$1.00** |
| API calls (Encrypt/Decrypt/GenerateDataKey) | $0.03 / 10 000 calls | ~20 000 / mo | **$0.06** |
| **KMS subtotal** | | | **~$1.05** |

API-call volume drivers: SNS encrypted publish, Secrets Manager reads, S3 PUT/GET on encrypted buckets, Lambda env-var decryption at cold start, DDB write encryption.

### 3.2 Secrets Manager

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Secret storage | $0.40 / secret / mo | 2 (Slack + Teams typical) | **$0.80** |
| `GetSecretValue` API | $0.05 / 10 000 calls | ~1 200 / mo | **<$0.01** |
| **Secrets Manager subtotal** | | | **~$0.80** |

If no chat webhooks / PD keys / Opsgenie keys are configured inline, this entire line is **$0**. Each additional channel (PagerDuty, Opsgenie, generic webhook) adds $0.40/mo.

### 3.3 AWS Budgets

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| First 2 budgets | **Free** | 2 | $0 |
| Additional budgets | $0.02 / budget / day = $0.62 / budget / mo | varies | varies |

Cost per scenario:

| Scenario | Number of budgets in `var.budgets_items` | Paid budgets | Cost |
|---|---|---|---|
| Minimal example | 1 (account only) | 0 | **$0** |
| Small prod (1 account + 2 service) | 3 | 1 | **$0.62** |
| Production example | 9 (1 account + 5 service + 3 tag) | 7 | **$4.34** |
| Large enterprise with cost-category budgets | 15 | 13 | **$8.06** |

Note: AWS Budget Actions are free; only the budget count incurs charges.

### 3.4 AWS Cost Explorer API

Cost Explorer charges $0.01 per API request.

| Driver | Calls / mo | Cost |
|---|---|---|
| `finops-metrics` aggregator (daily, ~7 calls for commitment + anomaly + forecast KPIs) | ~210 / mo | **$2.10** |
| `budgets` performance Lambda (daily anomaly correlation) | ~30 / mo | **$0.30** |
| Console / ad-hoc usage by the FinOps team | varies | $0.20–$2.00 |
| **Cost Explorer subtotal** | | **~$2.60–$4.40** |

### 3.5 AWS Config — **the dominant cost line**

Two billable dimensions:

1. **Configuration items recorded** (every tracked resource creation or change):

| Volume tier (per region per month) | Unit price |
|---|---|
| First 100 000 CIs | $0.003 / CI |
| Next 400 000 CIs | $0.0012 / CI |
| Beyond 500 000 CIs | $0.0006 / CI |

2. **Rule evaluations** (every time a rule re-runs against a resource):

| Volume tier | Unit price |
|---|---|
| First 100 000 evaluations | $0.001 / evaluation |
| Next 400 000 | $0.0008 / evaluation |
| Beyond 500 000 | $0.0005 / evaluation |

The framework's `tag-governance` module triggers on configuration changes, so each tracked-resource change pays once for the CI and once per applicable rule evaluation.

#### Worked examples (eu-central-1)

| Account | Churn assumption | CIs / mo | **Config recorder cost** |
|---|---|---|---|
| Sandbox | 5 changes / resource / mo | 1 000 | **~$4** |
| Sandbox | 30 changes / resource / mo | 6 000 | **~$24** |
| Small prod | 10 changes / resource / mo | 20 000 | **~$80** |
| Small prod | 30 changes / resource / mo | 60 000 | **~$240** |
| Mid-size (10k res.) | 20 changes / resource / mo | 200 000 | **~$540** |
| Mid-size (10k res.) | 30 changes / resource / mo | 300 000 | **~$720** |
| Large enterprise (50k res.) | 30 changes / resource / mo | 1 500 000 | **~$1 700** |

**Real-world churn varies wildly** — a static EC2-heavy account might see 2–5 changes per resource per month, while a Kubernetes-heavy account where pods, EBS volumes, ENIs, and load balancers churn constantly can hit 50+. Measure your own with `aws configservice get-aggregate-discovered-resource-counts` after a month.

**If `enable_config_recorder = false`** (set this when Config is already on at the org level), you pay only the rule-evaluation cost (~$5–$200/mo depending on size), not the CI recording cost.

### 3.6 S3 storage

| Bucket | Typical size | Storage class | Cost |
|---|---|---|---|
| Cost-data (CUR + FOCUS) | ~100 MB/mo new × 3 mo Standard + the rest in GLACIER_IR | Mixed | **<$0.10** |
| Athena results | <50 MB (30-day expiration) | Standard | **<$0.01** |
| AWS Config delivery bucket | ~1–5 GB/mo, retained ≥ 7 yr | Standard | $0.02–$2.50 in year 1; ~$5–$30/mo by year 7 |

Lifecycle math for the cost-data bucket:
- Standard: $0.024 / GB / mo
- Glacier Instant Retrieval: $0.004 / GB / mo (still Athena-queryable)
- Deep Archive (noncurrent versions only): $0.0018 / GB / mo

A bank that has been running CUR 2.0 for 7 years accumulates ~8 GB; 90 days at Standard + 6.75 years at GLACIER_IR ≈ **$0.18/mo at year 7**. Trivial. The Config bucket is the larger of the three by far in any real account.

### 3.7 SNS

| Item | Unit price | Volume | Cost |
|---|---|---|---|
| Publishes | $0.50 / 1M | ~5 000 / mo (budget breaches + governance + reports + alarms) | **<$0.01** |
| Email deliveries | First 1 000 free; $2 / 100 000 after | ~5 000 / mo | **$0.08** |
| Lambda deliveries (dispatcher subscription) | $0.60 / 1M | ~5 000 / mo | **<$0.01** |
| **SNS subtotal** | | | **~$0.10** |

### 3.8 EventBridge

| Rule | Frequency | Events / mo |
|---|---|---|
| `instance-scheduler-tick` | every 5 min | 8 640 |
| `idle-cleanup-*` (six rules) | weekly each | 24 |
| `kpi-aggregator` | daily | 30 |
| `budget-performance` | daily | 30 |
| `cost-data-health` | daily | 30 |
| `untagged-cost-report` | weekly | 4 |
| `tag-compliance` (Config compliance changes) | event-driven | ~100–1 000 |
| `tag-drift` (Tag Change on Resource) | event-driven | ~10–500 |
| `crawler-state` (Glue crawler state changes) | event-driven | ~1–5 |

Total ~10 000 / mo × $1 / 1M = **<$0.01**.

### 3.9 Lambda

13 Lambdas across the framework. X-Ray Active tracing is on by default (toggle via per-module `xray_tracing_enabled`).

| Function | Invocations / mo | Avg duration | Memory | GB-seconds |
|---|---|---|---|---|
| `dispatcher` (alerting) | 500 | 1 s | 256 MB | 125 |
| `idle-ebs` | 4 | 30 s | 512 MB | 60 |
| `idle-eip` | 4 | 10 s | 256 MB | 10 |
| `idle-snapshot` | 4 | 30 s | 512 MB | 60 |
| `idle-nat` | 4 | 30 s | 256 MB | 30 |
| `idle-eni` | 4 | 30 s | 256 MB | 30 |
| `idle-lb` | 4 | 30 s | 512 MB | 60 |
| `scheduler` (5-min tick) | 8 640 | 10 s | 512 MB | 43 200 |
| `scheduler-discovery` (weekly) | 4 | 60 s | 512 MB | 120 |
| `kpi-aggregator` (daily) | 30 | 120 s | 512 MB | 1 800 |
| `budget-performance` (daily) | 30 | 60 s | 512 MB | 900 |
| `cost-data-health` (daily) | 30 | 30 s | 256 MB | 240 |
| `tag-governance-untagged-cost` (weekly) | 4 | 60 s | 512 MB | 120 |
| **Totals** | **~9 260** | | | **~46 755 GB-s** |

Free tier (perpetual, per account):
- 1 000 000 requests/mo
- 400 000 GB-seconds/mo

Framework uses **~1% of request free tier** and **~12% of compute free tier**. Lambda cost = **$0** under free tier.

Even without free tier:
- $0.20 / 1M requests → $0.002
- $0.0000166667 / GB-s → $0.78

So worst-case Lambda cost is **<$1.00 / mo**.

**Reserved concurrency** (set via per-module `reserved_concurrent_executions`) is a **quota mechanism, not a billing item** — it doesn't add cost. It's useful as an incident-mode kill switch (`= -1`) or to cap a noisy Lambda.

### 3.10 X-Ray Active tracing (new in v0.2.1)

Every Lambda the framework deploys has `tracing_config { mode = "Active" }` and the `xray:PutTraceSegments` + `xray:PutTelemetryRecords` IAM permissions, gated by `var.xray_tracing_enabled` (default `true`).

| Item | Unit price | Volume | Cost |
|---|---|---|---|
| Traces recorded | $5.00 / 1M | ~9 260 / mo (one per Lambda invocation) | **<$0.05** |
| Traces retrieved + scanned | $0.50 / 1M each | ad-hoc operator queries | **<$0.05** |
| **X-Ray subtotal** | | | **~$0.10** |

Effectively free at framework volume; the value is in cold-start debugging and integration-failure forensics. Toggle off (`xray_tracing_enabled = false`) only if you're trying to make the framework footprint as minimal as possible — the savings are pennies.

### 3.11 SQS (DLQs)

One queue per Lambda (13 in total), near-zero traffic (only failed invocations land here). SSE-SQS managed encryption is **free**. Free tier of 1M requests/mo covers normal operation. **Cost: $0**.

### 3.12 CloudWatch Logs

| Component | Ingestion volume / mo | Cost @ $0.57/GB |
|---|---|---|
| All 13 Lambdas combined | ~40 MB | **~$0.03** |

Storage @ $0.03 / GB / mo, configurable retention:
- 365-day retention: cumulative ~480 MB → **~$0.02 / mo**
- 7-year retention: cumulative ~3.4 GB → **~$0.11 / mo**

### 3.13 CloudWatch Custom Metrics ⚠ material line

The framework emits a substantial set of custom metrics across 5 namespaces. AWS charges for each unique `(namespace, metric_name, dimension_set)` combination.

| Namespace | Source | Distinct metrics (typical) |
|---|---|---|
| `FinOps/Alerting` | dispatcher | 2–4 |
| `FinOps/Budgets` | budget-performance | 12–22 (VariancePct, BurnRateDaysToBreach × N budgets + adherence + active count) |
| `FinOps/CostDataExports` | health-check | 4 (delivery / crawler / queryability / object count) |
| `FinOps/IdleResources` | 6 cleanup Lambdas | 24 (MonthlyWasteUsd / FoundCount / ActionsTakenCount / RunSavingsUsd × 6 ResourceType dims) |
| `FinOps/InstanceScheduler` | scheduler | 12 (8 action counters + ManagedResourceCount × 4 ResourceType dims) |
| `FinOps/KPIs` | kpi-aggregator | 30–80 depending on toggles |
| `FinOps/TagGovernance` | untagged-cost report | 1–6 |

| Volume tier | Unit price |
|---|---|
| First 10 000 metrics | $0.30 / metric / mo |
| Next 240 000 | $0.10 / metric / mo |
| Beyond 250 000 | $0.05 / metric / mo |
| Beyond 1 000 000 | $0.02 / metric / mo |

Typical metric count and cost:

| Configuration | Distinct metrics | Cost @ $0.30 |
|---|---|---|
| Minimal (most modules off, no custom KPIs, no per-tag-value dashboard) | ~10 | **$3** |
| Small production | ~70 | **$21** |
| Production with `tag_value_dashboard_tag` set to `BusinessUnit` (10 values) | ~85 | **$25.50** |
| Production with `tag_value_dashboard_tag = "BusinessUnit"` + 5 custom KPIs (each with `_7d/_30d/_WoW` trends) | ~110 | **$33** |
| Large enterprise: tag-value dashboard over 50 BU values + 20 custom KPIs | ~180 | **$54** |

**`finops_metrics_tag_value_dashboard_tag` is the largest variable.** Each distinct tag value emits a metric per day. Choose a tag with bounded cardinality (BusinessUnit: ~10–50 values is fine; AccountId or Owner with hundreds of values gets pricey). The aggregator publishes once per day per value, so the metric stays "active" for the rest of the month from CloudWatch's billing perspective.

`finops_metrics_trend_metrics_enabled = true` (default) adds 3 derived metrics (`_7dAvg`, `_30dAvg`, `_WoWDriftPct`) per scalar KPI — typically ~15 extra metrics.

To minimize: set `finops_metrics_tag_value_dashboard_tag = null`, disable trend metrics, and prune `finops_metrics_builtin_kpis_enabled` for KPIs an external tool (Cloudability) already owns.

### 3.14 CloudWatch Dashboards

The framework auto-provisions **5 dashboards**:

| Module | Dashboard |
|---|---|
| cost-data-exports | health-check pipeline (CUR freshness, crawler, Athena) |
| budgets | adherence, variance, burn-rate (per-budget) |
| idle-resource-cleanup | waste, savings, found-count (per resource type) |
| instance-scheduler | actions, savings curve, DLQ depth |
| finops-metrics | KPI scorecard + per-tag-value widgets (Lambda re-PUTs daily) |

Pricing: first 3 dashboards free, then **$3 / dashboard / month**.

| Configuration | Paid dashboards | Cost |
|---|---|---|
| Minimal (1–2 modules on, 0–2 dashboards) | 0 | **$0** |
| Production (all 5 dashboards) | 2 | **$6** |

### 3.15 CloudWatch Alarms

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Standard-resolution alarm | $0.10 / alarm / mo | ~24 (Lambda errors + DLQ depth + KPI thresholds + WoW drift + burn-rate metric-math + budget adherence + waste totals + CUR freshness + custom-KPI alarms) | $2.40 |
| Free tier | — | 10 alarms | -$1.00 |
| **CloudWatch alarms subtotal** | | | **~$1.40** |

Metric-math alarms (the burn-rate alarm in `budgets`) are priced the same as standard alarms.

### 3.16 DynamoDB

| Table | Storage / mo | RW units / mo | Cost |
|---|---|---|---|
| `alerting-events` (DEDUP + AUDIT) | <1 GB | low (per-event) | **<$0.10** |
| `budgets-state` (trend + audit) | <0.5 GB | very low (daily writes) | **<$0.05** |
| `idle-findings` (STATE + ACTION) | 1–5 GB | low | **<$0.30** |
| `scheduler-state` (STATE + ACTION + GSI) | 0.5–3 GB | moderate (per-tick writes × 8 640) | **~$0.50** |
| `kpi-snapshots` (one row / KPI / day) | <100 MB | very low (~10 writes/day) | **<$0.01** |
| **DynamoDB subtotal** | | | **~$1.00** |

PITR is on for every table; that's roughly +20% of storage cost (still <$0.30/mo combined).

### 3.17 Athena

$5 per TB scanned, with a 10 MB minimum per query.

| Scenario | Queries / mo | Avg bytes scanned | Cost |
|---|---|---|---|
| Light (1 analyst, monthly chargeback only) | 20 | 200 MB | **<$0.05** |
| Moderate (weekly reporting + ad-hoc + KPI aggregator) | 100 | 1 GB | **$0.50** |
| Heavy (dashboard backing, daily refresh) | 1 000 | 2 GB | **$10.00** |

Use partition pruning (`billing_period = date_format(current_date, '%Y-%m')`) aggressively — the framework's named queries and `finops-metrics` queries all do this. Without it, full-table scans can spike costs an order of magnitude.

### 3.18 Glue Data Catalog + Security Configuration

| Item | Cost |
|---|---|
| Catalog storage (~5 tables) | $1 / 1M objects/mo → **~$0** |
| Crawler runs | $0.44 / DPU-hour, 2 DPU min, daily ~5-min runs → **~$0.07/mo** |
| Glue Security Configuration | **Free** (only enforces SSE-KMS on the crawler's logs / bookmarks) |

---

## 4. Framework-only baseline (Config excluded)

This is the "always-on" cost that doesn't scale with account size, for a typical production deployment:

| Component | Monthly cost |
|---|---|
| KMS | $1.05 |
| Secrets Manager (1 Slack + 1 Teams secret) | $0.80 |
| AWS Budgets (production example, 9 budgets) | $4.34 |
| Cost Explorer API (`finops-metrics` + `budgets` daily) | $2.40 |
| S3 (cost-data + athena-results) | <$0.10 |
| SNS | $0.10 |
| EventBridge | <$0.01 |
| Lambda | $0 (free tier) |
| X-Ray | $0.10 |
| SQS (DLQs) | $0 |
| CloudWatch Logs (365-day default) | $0.05 |
| **CloudWatch Custom Metrics (~70 distinct)** | **$21** |
| **CloudWatch Dashboards (5 — 2 paid)** | **$6** |
| CloudWatch Alarms (~24, minus 10 free) | $1.40 |
| DynamoDB (5 tables) | $1.00 |
| Athena (moderate usage) | $0.50 |
| Glue (crawler runs) | $0.07 |
| **Framework baseline** | **~$39 / month** |

The two biggest line items in the baseline are now **CloudWatch custom metrics ($21)** and **CloudWatch dashboards ($6)** — both invisible until v0.2.1 added the trend metrics and per-tag-value dashboards.

---

## 5. Full scenarios

### 5.1 Sandbox — `examples/minimal`

`idle_cleanup_enabled = false`, `instance_scheduler_enabled = false`, `finops_metrics_enabled = false`, `tag_governance_enabled = false`, no webhooks. AWS Config recorder *not* provisioned (no tag-governance).

| Component | Cost |
|---|---|
| KMS | $1.05 |
| Secrets Manager (no webhooks) | $0 |
| AWS Budgets (1 budget, free tier) | $0 |
| Cost Explorer API | $0 |
| S3 | <$0.10 |
| SNS | <$0.05 |
| Lambda (only dispatcher, no events triggering it) | $0 |
| X-Ray (one Lambda, near-zero invocations) | <$0.01 |
| CloudWatch Logs / Alarms | <$0.30 |
| CloudWatch Custom Metrics (~5 from dispatcher only) | $1.50 |
| CloudWatch Dashboards (0 — none deployed in minimal) | $0 |
| DynamoDB (alerting events table only) | <$0.05 |
| Athena (light, 20 queries) | <$0.05 |
| **Sandbox total** | **~$3 / month** |

If `tag_governance_enabled = true` is added later with the default `tag_governance_record_global_resources = true`, expect AWS Config to add **$18+ / month** for a 200-resource sandbox.

### 5.2 Small production, single region

2 000 resources, moderate churn (~10 changes/resource/mo), full production example with all Lambdas on, primary region only.

| Component | Cost |
|---|---|
| Framework baseline | $39 |
| AWS Config (20 000 CIs + 20 000 evals @ first-tier pricing) | $80 |
| **Small production total** | **~$120 / month** |

### 5.3 Small production, primary + 1 secondary region

Same account, `aws_secondary_regions = ["us-east-1"]`. The scanning modules (`idle-resource-cleanup`, `instance-scheduler`) now iterate two regions; everything else stays in the primary.

| Delta vs §5.2 | Cost |
|---|---|
| Lambda invocations (scheduler ticks scan 2 regions per invocation — same invocation count, ~2× runtime) | still $0 (free tier headroom intact) |
| Cost Explorer API (no change — still single account) | $0 |
| CloudWatch custom metrics (additional Region dimension on scheduler + idle metrics) | +$3 |
| AWS Config in `us-east-1` (only if `enable_config_recorder = true` AND a separate Config recorder is provisioned in us-east-1 — not done by this module) | $0 |
| Athena (no change) | $0 |
| **Multi-region total** | **~$140 / month** |

Note: scaling to 5+ secondary regions is still well within Lambda free tier; the multi-region cost driver is **always AWS Config** if you provision a Config recorder per region.

### 5.4 Mid-size production account

10 000 resources, ~30 changes/resource/mo (300 000 CIs/mo).

| Component | Cost |
|---|---|
| Framework baseline | $40 |
| AWS Config — CIs (100k @ $0.003 + 200k @ $0.0012) | $540 |
| AWS Config — rule evals (100k @ $0.001 + 200k @ $0.0008) | $260 |
| AWS Config bucket S3 storage (cumulative, year-1) | $1 |
| Athena (moderate-to-heavy usage by FinOps team) | $2 |
| **Mid-size total** | **~$840 / month** |

If Config recorder is **already enabled org-wide** (recommended; the framework's tag-governance module re-uses it instead of provisioning its own), CI cost drops to $0 and only rule-eval cost remains: **~$270 / month**. Combined: **~$310 / month**.

### 5.5 Large enterprise account

50 000 resources, ~30 changes/resource/mo (1.5 M CIs/mo).

| Component | Cost |
|---|---|
| Framework baseline | $40 |
| AWS Config — CIs (100k @ $0.003 + 400k @ $0.0012 + 1M @ $0.0006) | $1 380 |
| AWS Config — rule evals (100k + 400k + 1M, same volume tiers) | $920 |
| AWS Config bucket S3 (heavy churn) | $10 |
| Athena (heavy usage) | $10 |
| **Large enterprise total** | **~$2 350 / month** |

With Config recorder already enabled org-wide: **~$980 / month** (rule evals + baseline only).

---

## 6. Cost variance — what knobs actually matter

Ranked by impact:

1. **Whether AWS Config is enabled org-wide** — single biggest variable. If the org already runs Config (typical with Control Tower), the framework's `tag-governance` module re-uses that recorder and you save 60–80% of total framework cost. If not, the recorder needs to be provisioned alongside.
2. **`tag_governance_compliance_resource_types`** — every additional type multiplies rule evaluations. Default has 9 types; trimming to 4 (EC2 + RDS + S3 + Lambda) cuts Config rule cost by ~55%.
3. **`tag_governance_required_tags` count** — more than 6 tags triggers a second Config rule (chunking), doubling rule evaluations on every change.
4. **`finops_metrics_tag_value_dashboard_tag`** — emits one CloudWatch metric per distinct tag value per day. 10–50 values is fine ($3–$15/mo); 500+ values can hit $150/mo. Pick a low-cardinality allocation tag (BusinessUnit, CostCenter), never Owner or AccountId.
5. **`finops_metrics_custom_kpis` count** — each custom KPI adds one daily Athena query + 1 base metric + (if `trend_metrics_enabled`) 3 derived metrics. 5 custom KPIs = ~$6/mo extra in metrics + pennies in Athena.
6. **`aws_secondary_regions`** — Lambda cost stays free-tier-friendly, but the Region dimension on scheduler + idle metrics multiplies the custom-metric count. +$3/mo per added region (linearly).
7. **Athena query patterns** — partition-pruned queries are pennies; full-table scans on 7 years of CUR are dollars per query. The framework's named queries are all partition-pruned.
8. **`log_retention_days`** — 2557 (7 yr) is for SOX/PCI. Non-prod accounts should drop to 365.
9. **`budgets_items` count** — first 2 free, then $0.62 / budget / mo. Cost-category-scoped budgets are useful but additive.
10. **`xray_tracing_enabled`** — adds ~$0.10/mo. Not a real lever — leave it on; the cold-start debug value far outweighs the cost.
11. **`finops_metrics_snapshot_retention_days`** — controls DDB storage for KPI history. Default 400d is ~100 MB total. Setting it to 7 yr is still <$1 / mo.

---

## 7. ROI vs. potential savings

Why the framework is cheap relative to what it catches:

| Capability | Typical savings on a $100k/mo account |
|---|---|
| Idle EBS / EIP / snapshot / NAT / ENI / LB cleanup | 1–3% ($1k–$3k/mo) |
| Instance scheduling for non-prod | 30–60% of non-prod compute (often $5k–$15k/mo) |
| Tag governance (catches allocation gaps before invoice) | 2–4% of unallocated spend |
| Budget alerts + Budget Actions (catches spend drift early) | 2–5% ($2k–$5k/mo) |
| Untagged-cost report dollarization | makes tag campaigns prioritised by $ impact |
| Anomaly correlation in budgets (catches misconfigurations) | hard to model, but a single missed runaway resource can be $50k+ |
| RI / SP coverage KPIs in finops-metrics | 10–20% on eligible compute ($3k–$10k/mo) |

A typical FinOps program with this capability stack catches **5–15% of cloud spend** in its first year. On a $250k/mo account that's $12 500–$37 500/mo of avoidable spend — roughly **20–50× the framework's own cost** even in the large-bank scenario, and **200–500× in the mid-size scenario with shared Config**.

---

## 8. Recommendations to keep cost predictable

1. **First, check whether AWS Config is already enabled at the organization level.** Most banks using Control Tower have it. If so, set `enable_config_recorder = false` and let the framework re-use the org-managed recorder. Single biggest lever.
2. **Tune `tag_governance_compliance_resource_types`.** Start with EC2, RDS, S3, Lambda only; expand once tagging discipline is in place.
3. **Choose `finops_metrics_tag_value_dashboard_tag` carefully.** Use a bounded allocation tag (BusinessUnit, CostCenter), never high-cardinality (Owner, AccountId). Inspect with: `aws athena start-query-execution --query-string "SELECT COUNT(DISTINCT resource_tags['user_BusinessUnit']) FROM cur2"` before setting it.
4. **Use `examples/minimal` in sandboxes.** All execution Lambdas off, `cost_data_exports_focus_enabled = false`, shorter `log_retention_days`. Skip `tag_governance_enabled` until you have a real taxonomy.
5. **Teach analysts partition-pruning.** Athena query cost is entirely user-driven.
6. **Defer flipping `idle_cleanup_dry_run = false`** until you have a full reporting cycle of findings — running in dry-run mode is essentially free.
7. **Measure actual churn after one month.** Re-estimate Config costs using `aws configservice get-aggregate-discovered-resource-counts` and CloudTrail event counts.
8. **Start with fewer custom KPIs.** Add `finops_metrics_custom_kpis` entries one at a time and confirm each new Athena query is partition-pruned (uses `billing_period = date_format(current_date, '%Y-%m')`). Each KPI with trends enabled adds 4 metrics.
9. **Leave X-Ray on.** It costs cents and saves hours during a cold-start or integration debug.

---

## 9. Appendix — assumptions

| Assumption | Value used |
|---|---|
| Region | `eu-central-1` |
| Resource changes / month / resource | 30 (moderate) — varies 5–50 |
| CUR file size | 100 MB/mo per export, parquet compressed |
| Notification events / month | ~5 000 (budget alerts + governance + reports + Lambda alarms) |
| Cold starts / day per Lambda | ~20 (warm container reuse covers the rest) |
| Custom metrics per typical production deployment | ~70 distinct (namespace × name × dimension-set tuples) |
| Auto-provisioned dashboards in production | 5 |
| AWS Budgets free tier | First 2 budgets per account, per month |
| CloudWatch alarms free tier | First 10 standard-resolution alarms per account |
| CloudWatch dashboards free tier | First 3 per account |
| Lambda free tier | 1M requests + 400k GB-s per account per month, perpetual |
| Athena minimum scan | 10 MB per query (rounded up) |
| Pricing source | AWS public on-demand list as of 2026-05-31 |

### Pricing references used

- AWS KMS pricing: aws.amazon.com/kms/pricing
- AWS Secrets Manager pricing: aws.amazon.com/secrets-manager/pricing
- AWS Config pricing: aws.amazon.com/config/pricing
- Amazon S3 pricing: aws.amazon.com/s3/pricing
- AWS Lambda pricing: aws.amazon.com/lambda/pricing
- Amazon CloudWatch pricing: aws.amazon.com/cloudwatch/pricing (Custom Metrics, Dashboards, Alarms, Logs)
- AWS X-Ray pricing: aws.amazon.com/xray/pricing
- Amazon SNS / SQS / EventBridge pricing: respective product pages
- Amazon Athena pricing: aws.amazon.com/athena/pricing
- AWS Budgets pricing: aws.amazon.com/aws-cost-management/aws-budgets/pricing
- AWS Glue pricing: aws.amazon.com/glue/pricing

For exact numbers in your account, run the framework's own Athena queries against the CUR after 1–2 months of operation — you'll see real cost rather than estimates.
