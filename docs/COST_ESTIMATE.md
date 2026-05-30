# Cost Estimate — Solidus FinOps Deployment

**As-of date:** 2026-05-29
**Region (primary):** `eu-central-1` (Frankfurt). Notes flag where US regions differ materially.
**Currency:** USD
**Source:** AWS public on-demand list pricing. Enterprise Discount Program (EDP) and private pricing can reduce these by 5–25%.

---

## 1. TL;DR

| Scenario | Resources in account | AWS Config recorder | **Monthly total** |
|---|---|---|---|
| Sandbox (`examples/minimal`, Config off, Lambdas off) | ~200 | off | **~$3** |
| Sandbox with Config recorder on | ~200 | on | **~$7** |
| Small production | ~2 000 | on | **~$90** |
| Mid-size production account | ~10 000 | on | **~$640** |
| Mid-size bank, Config already org-managed | ~10 000 | off (rules only) | **~$30** |
| Large enterprise account | ~50 000 | on | **~$2 320** |
| Large enterprise, Config already org-managed | ~50 000 | off (rules only) | **~$50** |

The framework's own moving parts cost **~$11 / month** regardless of account size (KMS + Budgets + Cost Explorer + DDB + CloudWatch + Lambda free-tier compute). **AWS Config is the dominant variable** and depends on how many resources the account holds and how often they change. If Config recording is already enabled at the organization level (typical with AWS Control Tower), the `tag-governance` module re-uses it and costs almost nothing extra.

---

## 2. What the framework provisions (cost-relevant inventory)

| AWS service | Resources created | Notes |
|---|---|---|
| KMS | 1 customer-managed key + 1 alias | Used by every other component |
| Secrets Manager | 0–2 secrets (Slack, Teams) | Only if webhooks configured |
| AWS Budgets | 1–10+ budgets | Driven by `var.budgets_items` map |
| AWS Cost & Usage Report 2.0 | 1 report definition (us-east-1) | **Free delivery**; pay only for S3 storage |
| BCM Data Exports (FOCUS 1.0) | 1 export | **Free delivery** |
| S3 | 3 buckets (cost-data, athena-results, config) | KMS-encrypted, lifecycle managed |
| Athena workgroup + Glue DB | 1 each | Per-query cost only |
| AWS Config | 1 recorder + N rule chunks + 1 delivery channel | The expensive line |
| EventBridge | ~5–7 rules | Scheduling + Config compliance triggers |
| SNS | 1 topic | Plus N email + 1 dispatcher Lambda subscription |
| Lambda | ~10 functions (dispatcher, 6× idle, scheduler, scheduler-discovery, kpi-aggregator, budget-perf, cost-data-health, tag-governance untagged-cost) | All within free tier in practice |
| SQS | One DLQ per Lambda | SSE-SQS managed encryption (free) |
| CloudWatch Logs | ~10 log groups + standard Lambda logs | Configurable retention (default 365 d) |
| CloudWatch Alarms | ~20 alarms (Lambda errors + DLQ depth + KPI thresholds + WoW drift + budget adherence + scheduler-action ceilings) | Most free-tier; few paid |
| DynamoDB | ~5 tables (alerting events, budgets state, idle findings, scheduler state, KPI snapshots) | All PAY_PER_REQUEST + CMK + PITR |
| Secrets Manager | 0–N secrets (per Slack / Teams / PagerDuty / Opsgenie / webhook channel configured inline) | KMS-encrypted |
| IAM | One role per Lambda + per service principal | No cost |

---

## 3. Per-service cost breakdown

All numbers below are **monthly**, in USD, at `eu-central-1` list pricing.

### 3.1 KMS

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Customer-managed key | $1.00 / CMK / mo | 1 | **$1.00** |
| API calls (Encrypt/Decrypt/GenerateDataKey) | $0.03 / 10 000 calls | ~15 000 / mo | **$0.05** |
| **KMS subtotal** | | | **~$1.05** |

API-call volume drivers: SNS encrypted publish, Secrets Manager reads, S3 PUT/GET on encrypted buckets, Lambda env-var decryption at cold start.

### 3.2 Secrets Manager

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Secret storage | $0.40 / secret / mo | 2 (Slack + Teams) | **$0.80** |
| `GetSecretValue` API | $0.05 / 10 000 calls | ~1 200 / mo (1 per cold start × 2 secrets × ~20 cold starts/day) | **<$0.01** |
| **Secrets Manager subtotal** | | | **~$0.80** |

If neither webhook is configured, this entire line is **$0**.

### 3.3 AWS Budgets

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| First 2 budgets | **Free** | 2 | $0 |
| Additional budgets | $0.02 / budget / day = $0.62 / budget / mo | varies | varies |

Cost per scenario:

| Scenario | Number of budgets in `var.budgets` | Paid budgets | Cost |
|---|---|---|---|
| Minimal example | 1 (account only) | 0 | **$0** |
| Small prod (1 account + 2 service) | 3 | 1 | **$0.62** |
| Bank production example | 9 (1 account + 5 service + 3 tag) | 7 | **$4.34** |
| Large enterprise with cost-category budgets | 15 | 13 | **$8.06** |

### 3.4 AWS Cost Explorer API

Cost Explorer charges $0.01 per API request.

| Driver | Calls / mo | Cost |
|---|---|---|
| `finops-metrics` aggregator (daily, ~7 calls per run for commitment + anomaly + forecast KPIs) | ~210 / mo | **$2.10** |
| Console / ad-hoc usage by the FinOps team | varies | $0.20–$2.00 |
| **Cost Explorer subtotal** | | **~$2.50–$4.00** |

Console usage is by the human team and not driven by the framework, but worth budgeting.

### 3.5 AWS Config — **the dominant cost line**

Two billable dimensions:

1. **Configuration items recorded** (every time a tracked resource is created or changes):

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

Assume churn = ~30 changes per resource per month (a moderate estimate for an active account with deploys and auto-scaling).

| Account | Resources | CIs / mo | Rule evals / mo (1 rule chunk) | CI cost | Eval cost | **Config total** |
|---|---|---|---|---|---|---|
| Sandbox | 200 | 6 000 | 6 000 | $18 | $6 | **~$24** |
| Small prod | 2 000 | 60 000 | 60 000 | $180 | $60 | **~$240** |

Wait, my earlier TL;DR used a lower churn assumption (~10/mo) for small prod. Both are defensible — the table below shows both:

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

| Bucket | Average size (typical bank) | Storage class | Cost |
|---|---|---|---|
| Cost-data (CUR + FOCUS) | ~100 MB/mo new × 3 mo Standard + the rest in GLACIER_IR | Mixed | **<$0.10** |
| Athena results | <50 MB (30-day expiration) | Standard | **<$0.01** |
| AWS Config delivery bucket | ~1–5 GB/mo, retained ≥ 7 yr | Standard | $0.02–$2.50 in year 1; ~$5–$30/mo by year 7 |

Lifecycle math for the cost-data bucket:
- Standard: $0.024 / GB / mo
- Glacier Instant Retrieval: $0.004 / GB / mo (still Athena-queryable)
- Deep Archive (noncurrent versions only): $0.0018 / GB / mo

A bank that has been running CUR 2.0 for 7 years accumulates ~8 GB; 90 days at Standard + 6.75 years at GLACIER_IR ≈ **$0.18/mo at year 7**. Trivial.

The Config bucket is the larger of the three by far in any real account.

### 3.7 SNS

| Item | Unit price | Volume | Cost |
|---|---|---|---|
| Publishes | $0.50 / 1M | ~5 000 / mo (anomalies + budget alerts + governance + reports) | **<$0.01** |
| Email deliveries | First 1 000 free; $2 / 100 000 after | ~5 000 / mo | **$0.08** |
| HTTPS deliveries (chat-notifier subscription) | $0.60 / 1M | ~5 000 / mo | **<$0.01** |
| **SNS subtotal** | | | **~$0.10** |

### 3.8 EventBridge

| Rule | Frequency | Events / mo |
|---|---|---|
| `instance-scheduler-tick` | every 5 min | 8 640 |
| `idle-cleanup-weekly` | weekly | 4 |
| `coverage-weekly` | weekly | 4 |
| `tag-compliance` (Config compliance changes) | event-driven | ~100–1 000 |

Total ~10 000 / mo × $1 / 1M = **<$0.01**.

### 3.9 Lambda

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

### 3.10 SQS (DLQs)

One queue per Lambda (~13 in total), near-zero traffic (only failed invocations land here). SSE-SQS managed encryption is **free**. Free tier of 1M requests/mo covers normal operation. **Cost: $0**.

### 3.11 CloudWatch Logs

| Component | Ingestion volume / mo | Cost @ $0.57/GB |
|---|---|---|
| All ~13 Lambdas combined | ~30 MB | **~$0.02** |

Storage @ $0.03 / GB / mo, configurable retention:
- 365-day retention: cumulative ~360 MB → **~$0.01 / mo**
- 7-year retention: cumulative ~2.5 GB → **~$0.08 / mo**

### 3.12 CloudWatch Alarms

| Item | Unit price | Quantity | Cost |
|---|---|---|---|
| Standard-resolution alarm | $0.10 / alarm / mo | ~20 (Lambda errors + DLQ depth + KPI thresholds + WoW drift + budget adherence + scheduler ceilings) | $2.00 |
| Free tier | — | 10 alarms | -$1.00 |
| **CloudWatch alarms subtotal** | | | **$1.00** |

### 3.12a DynamoDB

| Table | Storage / mo | RW units / mo | Cost |
|---|---|---|---|
| `alerting-events` (DEDUP + AUDIT) | <1 GB | low (per-event) | **<$0.10** |
| `budgets-state` (trend + audit) | <0.5 GB | very low (daily writes) | **<$0.05** |
| `idle-findings` (STATE + ACTION) | 1–5 GB | low | **<$0.30** |
| `scheduler-state` (STATE + ACTION + GSI) | 0.5–3 GB | moderate (per-tick writes × 8 640) | **~$0.50** |
| `kpi-snapshots` (one row / KPI / day) | <100 MB | very low (~10 writes/day) | **<$0.01** |
| **DynamoDB subtotal** | | | **~$1.00** |

### 3.13 Athena

$5 per TB scanned, with a 10 MB minimum per query.

| Scenario | Queries / mo | Avg bytes scanned | Cost |
|---|---|---|---|
| Light (1 analyst, monthly chargeback only) | 20 | 200 MB | **<$0.05** |
| Moderate (weekly reporting + ad-hoc) | 100 | 1 GB | **$0.50** |
| Heavy (dashboard backing, daily refresh) | 1 000 | 2 GB | **$10.00** |

Use partition pruning (`year=...` + `month=...`) aggressively — without it, full-table scans can spike costs an order of magnitude.

### 3.14 Glue Data Catalog

Pricing is $1 per million objects per month for storage and $1 per million requests. The framework creates ~5 tables. **Cost: ≈ $0**.

---

## 4. Framework-only baseline (Config excluded)

This is the "always-on" cost that doesn't scale with account size:

| Component | Monthly cost |
|---|---|
| KMS | $1.05 |
| Secrets Manager (1 Slack + 1 Teams secret) | $0.80 |
| AWS Budgets (production example, 9 budgets) | $4.34 |
| Cost Explorer API (`finops-metrics` daily aggregator) | $2.10 |
| S3 (cost-data + athena-results) | <$0.10 |
| SNS | $0.10 |
| EventBridge | <$0.01 |
| Lambda | $0 (free tier) |
| SQS (DLQs) | $0 |
| CloudWatch Logs (365-day default) | <$0.05 |
| CloudWatch Alarms | $1.00 |
| DynamoDB (5 tables) | $1.00 |
| Athena (moderate usage) | $0.50 |
| **Framework baseline** | **~$11 / month** |

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
| CloudWatch Logs / Alarms | <$0.20 |
| DynamoDB (alerting events table only) | <$0.05 |
| Athena (light, 20 queries) | <$0.05 |
| **Sandbox total** | **~$2 / month** |

If `tag_governance_enabled = true` is added later with a default `tag_governance_record_global_resources = true`, expect AWS Config to add **$18+ / month** for a 200-resource sandbox.

### 5.2 Small production

2 000 resources, moderate churn (~10 changes/resource/mo), full production example with all Lambdas on.

| Component | Cost |
|---|---|
| Framework baseline (KMS, Secrets Manager, etc.) | $7.50 |
| AWS Config (20 000 CIs + 20 000 evals @ first-tier pricing) | $80 |
| **Small production total** | **~$90 / month** |

### 5.3 Mid-size production account

10 000 resources, ~30 changes/resource/mo (300 000 CIs/mo).

| Component | Cost |
|---|---|
| Framework baseline | $7.50 |
| AWS Config — CIs (100k @ $0.003 + 200k @ $0.0012) | $540 |
| AWS Config — rule evals (100k @ $0.001 + 200k @ $0.0008) | $260 |
| AWS Config bucket S3 storage (cumulative, year-1) | $1 |
| Athena (moderate-to-heavy usage by FinOps team) | $2 |
| **Mid-size total** | **~$810 / month** |

If Config recorder is **already enabled org-wide** (recommended; the framework's tag-governance module re-uses it instead of provisioning its own), CI cost drops to $0 and only rule-eval cost remains: **~$270 / month**. Combined: **~$280 / month**.

### 5.4 Large enterprise account

50 000 resources, ~30 changes/resource/mo (1.5 M CIs/mo).

| Component | Cost |
|---|---|
| Framework baseline | $7.50 |
| AWS Config — CIs (100k @ $0.003 + 400k @ $0.0012 + 1M @ $0.0006) | $1 380 |
| AWS Config — rule evals (100k + 400k + 1M, same volume tiers) | $920 |
| AWS Config bucket S3 (heavy churn) | $10 |
| Athena (heavy usage) | $10 |
| **Large enterprise total** | **~$2 320 / month** |

With Config recorder already enabled org-wide: **~$950 / month** (rule evals only).

---

## 6. Cost variance — what knobs actually matter

Ranked by impact:

1. **Whether AWS Config is enabled org-wide** — single biggest variable. If the org already runs Config (typical with Control Tower), the framework's `tag-governance` module re-uses that recorder and you save 60–80% of total framework cost. If not, the recorder needs to be provisioned alongside.
2. **`tag_governance_compliance_resource_types`** — every additional type multiplies rule evaluations. Default has 9 types; trimming to 4 (EC2 + RDS + S3 + Lambda) cuts Config rule cost by ~55%.
3. **`tag_governance_required_tags` count** — more than 6 tags triggers a second Config rule (chunking), doubling rule evaluations on every change.
4. **`aws_secondary_regions`** — adding regions to scanning modules (`idle-resource-cleanup`, `instance-scheduler`) doesn't materially change Lambda cost (still free-tier-comfortable) but DOES multiply Cost Explorer + Athena calls if you also enable per-region KPIs in `finops-metrics`.
5. **Athena query patterns** — partition-pruned queries are pennies; full-table scans on 7 years of CUR are dollars per query. The framework's named queries are partition-pruned.
6. **`log_retention_days`** — 2557 (7 yr) is for SOX/PCI. Non-prod accounts should drop to 365.
7. **`budgets_items` count** — first 2 free, then $0.62 / budget / mo. Cost-category-scoped budgets are useful but additive.
8. **`finops_metrics_custom_kpis` count** — each custom KPI adds one Athena query per daily aggregator run. 10 custom KPIs × 30 days × ~10 MB scanned = trivial; 10 custom KPIs each scanning a full CUR = expensive.
9. **`finops_metrics_tag_value_dashboard_tag`** — emits one CloudWatch metric per distinct tag value per day. Hundreds of values → still pennies; thousands → meaningful.
10. **`finops_metrics_snapshot_retention_days`** — controls DDB storage for KPI history. Default 400d is ~100 MB total. Setting it to 7 yr is still <$1 / mo.

---

## 7. ROI vs. potential savings

Why the framework is cheap relative to what it catches:

| Capability | Typical savings on a $100k/mo account |
|---|---|
| Idle EBS / EIP / snapshot cleanup | 1–3% ($1k–$3k/mo) |
| Instance scheduling for non-prod | 30–60% of non-prod compute (often $5k–$15k/mo) |
| RI / SP coverage optimization | 10–20% on eligible compute ($3k–$10k/mo) |
| Anomaly detection (catches misconfigurations) | hard to model, but a single missed runaway resource can be $50k+ |
| Budget alerts (catches spend drift early) | 2–5% ($2k–$5k/mo) |

A typical FinOps program with this capability stack catches **5–15% of cloud spend** in its first year. On a $250k/mo account that's $12 500–$37 500/mo of avoidable spend — roughly **20–50× the framework's own cost** even in the large-bank scenario, and **200–500× in the mid-bank scenario with shared Config**.

---

## 8. Recommendations to keep cost predictable

1. **First, check whether AWS Config is already enabled at the organization level.** Most banks using Control Tower have it. If so, leave `tag_governance_record_global_resources = false` and let the framework re-use the org-managed recorder. Single biggest lever.
2. **Tune `tag_governance_compliance_resource_types`.** Start with EC2, RDS, S3, Lambda only; expand once tagging discipline is in place.
3. **Use `examples/minimal` in sandboxes.** All execution Lambdas off, `cost_data_exports_focus_enabled = false`, shorter `log_retention_days`.
4. **Teach analysts partition-pruning.** Athena query cost is entirely user-driven.
5. **Defer flipping `idle_cleanup_dry_run = false`** until you have a full reporting cycle of findings — running in dry-run mode is essentially free.
6. **Measure actual churn after one month.** Re-estimate Config costs using `aws configservice get-aggregate-discovered-resource-counts` and CloudTrail event counts.
7. **Start with fewer custom KPIs.** Add `finops_metrics_custom_kpis` entries one at a time and confirm each new Athena query is partition-pruned (uses `billing_period = date_format(current_date, '%Y-%m')`).

---

## 9. Appendix — assumptions

| Assumption | Value used |
|---|---|
| Region | `eu-central-1` |
| Resource changes / month / resource | 30 (moderate) — varies 5–50 |
| CUR file size | 100 MB/mo per export, parquet compressed |
| Notification events / month | ~5 000 (anomalies + budget alerts + governance + reports + Lambda alarms) |
| Cold starts / day per Lambda | ~20 (warm container reuse covers the rest) |
| AWS Budgets free tier | First 2 budgets per account, per month |
| CloudWatch alarms free tier | First 10 standard-resolution alarms per account |
| Lambda free tier | 1M requests + 400k GB-s per account per month, perpetual |
| Athena minimum scan | 10 MB per query (rounded up) |
| Pricing source | AWS public on-demand list as of 2026-05-29 |

### Pricing references used

- AWS KMS pricing: aws.amazon.com/kms/pricing
- AWS Secrets Manager pricing: aws.amazon.com/secrets-manager/pricing
- AWS Config pricing: aws.amazon.com/config/pricing
- Amazon S3 pricing: aws.amazon.com/s3/pricing
- AWS Lambda pricing: aws.amazon.com/lambda/pricing
- Amazon CloudWatch pricing: aws.amazon.com/cloudwatch/pricing
- Amazon SNS / SQS / EventBridge pricing: respective product pages
- Amazon Athena pricing: aws.amazon.com/athena/pricing
- AWS Budgets pricing: aws.amazon.com/aws-cost-management/aws-budgets/pricing

For exact numbers in your account, run the framework's own Athena queries against the CUR after 1–2 months of operation — you'll see real cost rather than estimates.
