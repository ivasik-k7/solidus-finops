# Solidus FinOps — Executive Brief

**Audience:** CFO, FinOps lead, exec sponsor, cloud-finance partner.
**Purpose:** A 2-page summary of what the framework is, why it exists, what it
costs, and what business outcomes it produces. Designed to be circulated
in pre-read packs.
**As-of:** 2026-05-31. License: Apache 2.0.

---

## What it is

A production-grade Terraform framework that provisions a complete FinOps
capability stack into an AWS account. Aligned to the
[FinOps Foundation Framework](https://www.finops.org/framework/capabilities/)
across the **Understand**, **Quantify**, **Optimize**, and **Manage**
capability domains.

It is not a wrapper around `aws_budgets_budget`. It is the **execution +
enforcement + audit layer** of a FinOps practice — the part that
*acts*, not the part that visualises. It deliberately complements
commercial FinOps analytics tools (Cloudability, Apptio, Vantage) rather
than competing with them: those tools own dashboards; this framework
owns governance, auto-cleanup, scheduling, KPI mirrors, and a fully
audited trail of every action.

7 modules, all standalone-reusable, all encrypted at rest with a
customer-managed KMS key, all auditable through a single events bus.

---

## Why it exists

Four assumptions drive the design:

1. **Allocation must be reproducible.** Someone will ask, a year from
   now, how cost was allocated for a specific month to a specific
   business unit. Allocation logic therefore lives in HCL, in git, with
   full history. (Regulator, finance lead, internal audit — same need.)
2. **Destruction must be opt-in.** Mutation-capable Lambdas
   (idle-resource cleanup, instance scheduler) are off by default,
   dry-run when enabled, require explicit per-resource-type opt-in,
   and respect exception tags.
3. **Encryption at rest is the default.** KMS CMK on S3, SNS, DynamoDB,
   Secrets Manager, CloudWatch Logs. Webhooks live in Secrets Manager,
   not env vars.
4. **Silent failure is the worst failure.** Every Lambda has a DLQ + a
   CloudWatch error alarm + a DLQ-depth alarm wired to the events bus.

---

## What gets deployed

| Module | What it does | Headline output |
|---|---|---|
| **alerting** | Multi-channel events bus (Slack / Teams / PagerDuty / Opsgenie / email / SQS / webhooks) with severity routing, dedup, and audit log. | One SNS topic every other module publishes to. |
| **cost-data-exports** | CUR 2.0 + FOCUS 1.0 exports, Glue crawler, Athena workgroup, pre-built named-query library, daily health-check Lambda, cross-account reader roles for 3rd-party tools. | The cost data plumbing your analytics tool consumes. |
| **tag-governance** | AWS Config rules for required tags (chunked over the 6-tag limit), tag-drift detection via EventBridge, weekly untagged-cost dollarization, allocation Resource Groups. | A compliance layer that *catches missing tags before they affect the invoice*. |
| **budgets** | Polymorphic budgets (account / service / tag / cost-category), AWS Budget Actions for auto-enforcement on breach, daily performance Lambda (variance + burn-rate + adherence + anomaly correlation), DDB trend store, auto-dashboard, burn-rate metric-math alarm. | The control plane that *stops* spend from running away, not just reports on it. |
| **idle-resource-cleanup** | 6 resource types (EBS / EIP / snapshot / NAT / ENI / LB) with multi-region scanning, DDB-backed STATE + ACTION audit, two-phase EBS deletion, aging escalation, dry-run default. | Catches and (optionally) deletes wasted spend with a 7-year audit trail. |
| **instance-scheduler** | Tag-driven start/stop for EC2 / RDS instances / RDS clusters / ASGs, action-count blast-radius cap, weekly auto-discovery of scheduling candidates, multi-region, dry-run, spot-aware. | Non-prod compute spend down 30–60%. |
| **finops-metrics** | Daily KPI aggregator: allocation %, RI/SP coverage & utilization, anomaly impact, forecast drift, spend-by-service. + custom KPIs as Athena queries, DDB snapshot history (drives 7d/30d trend metrics + WoW drift alarms), auto per-tag-value dashboards. | The FinOps scorecard, in CloudWatch + SSM + DDB + SNS. |

---

## Cost of operation

| Account size | Monthly cost | Note |
|---|---|---|
| Sandbox (~200 resources, Lambdas off) | ~$5 | Config off |
| Small production (~2 000 resources) | **~$120** | Config on |
| Mid-size (~10 000 resources) | **~$840** | Config on |
| Mid-size, Config already org-managed | **~$310** | Recommended pattern |
| Large enterprise (~50 000 resources) | **~$2 350** | Config on |
| Large enterprise, Config org-managed | **~$980** | Recommended pattern |

AWS Config is the dominant variable. If Config is already enabled at the
organization level (typical with AWS Control Tower), the
`tag-governance` module re-uses it and you save 60–80% of the total.

Full cost model: see [COST_ESTIMATE.md](COST_ESTIMATE.md).

---

## ROI

On a $250k/month cloud spend, a typical first-year FinOps program with
this capability stack catches **5–15% of cloud spend** — $12 500 to
$37 500 per month of avoidable spend. That is **20–500× the
framework's own cost**.

The largest line items are usually:

| Capability | Typical first-year impact on a $250k/mo account |
|---|---|
| Instance scheduling for non-prod | $12k–$37k / mo saved (30–60% of non-prod compute) |
| Idle resource cleanup | $2.5k–$7.5k / mo (1–3% of total) |
| Budget alerts + auto-enforcement on breach | catches misconfigurations worth $5k–$50k single incidents |
| Tag governance | unlocks chargeback; quantifies "unallocated" spend (often 30–60% pre-program → <5% mature) |
| RI/SP coverage KPIs | 10–20% saved on eligible compute |

---

## Compliance posture

Designed for SOX / PCI / GDPR / DORA-regulated workloads from day one,
not retrofitted:

- **Customer-managed KMS** on every encryptable data plane.
- **`prevent_destroy = true`** on every audit-grade DDB table + S3
  bucket (CUR, Config delivery, idle findings, scheduler state, budget
  trend, alerting audit, KPI snapshots).
- **7-year (2557-day) log retention** option for SOX/PCI; 5-year (1827)
  for DORA. Configurable per-module.
- **CloudTrail + IAM least-privilege** by design; every Lambda has its
  own role; every policy carries a documented `# checkov:skip=`
  rationale where AWS forces `Resource = "*"`.
- **No hardcoded secrets.** Chat webhooks, PagerDuty keys, Opsgenie API
  keys all live in Secrets Manager and are fetched at runtime.
- **Apache 2.0 license** with explicit patent grant + NOTICE
  attribution. Internal modifications can be relicensed by the consumer
  organisation.

See [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md) for the regulatory mapping
and the [Documented Checkov suppressions appendix](COMPLIANCE_NOTES.md).

---

## Operational guarantees

| Guarantee | Mechanism |
|---|---|
| Every Lambda error lands in a DLQ | `dead_letter_config` on every function |
| Every Lambda error fires an alarm to the events bus | `aws_cloudwatch_metric_alarm` per Lambda + per DLQ |
| Every destructive action is audited for 7 years | DDB `ACTION#<iso-ts>` rows, TTL = 2557d |
| Every destructive action can be reversed | Dry-run mode + DDB undo trail + EBS phase-2 (snapshot first) |
| Every cost data record can be reproduced | CUR 2.0 source preserved; allocation logic in git |
| Every cross-account integration is locked to an external ID | `cross_account_readers` validation |
| Every encryption boundary uses the same CMK | KMS key rotation cascades automatically |
| Every Lambda is traceable end-to-end | X-Ray Active tracing on by default |

---

## What this framework will NOT do

Honest scope limits, so you don't have a wrong expectation:

- **It does not run dashboards.** Cloudability / QuickSight / PowerBI /
  Looker remain better at executive dashboards. The framework emits
  metrics + SSM mirrors so any of those tools can read them.
- **It does not estimate dollar values.** AWS hourly rates differ by
  region, change over time, and ignore RI/SP/EDP — any hardcoded rate
  table is wrong on day one. Dollar attribution belongs in CUR-backed
  analytics (where actual paid prices live). The framework emits action
  counts and DDB ACTION rows; the analytics layer joins them.
- **It does not span accounts by itself.** Today it operates per AWS
  account. Cross-account roll-up via AWS Organizations + delegated
  admin is on the v1.0 roadmap.
- **It does not auto-tag resources.** Tag governance is detect-only by
  design. Auto-tagging silently masks the underlying discipline problem
  and creates an unauditable shadow of "machine-applied" tags.
  Enforcement belongs at creation time (IAM `RequestTag` conditions or
  Service Control Policies).
- **It does not replace Compute Optimizer or Cost Anomaly Detection.**
  Those AWS-native services are free and remain the right primitives.
  The framework's `finops-metrics` reads from Cost Explorer (which
  consumes anomaly data); it doesn't reimplement anomaly detection.

---

## Roadmap (next 90 days)

- **AWS Organizations / multi-account capability.** Deploy in a
  delegated admin account, scan members via cross-account roles.
  Single biggest scope multiplier in the backlog.
- **Rightsizing recommendation pipeline.** Pull Compute Optimizer +
  Cost Optimization Hub findings into the same DDB STATE + ACTION
  lifecycle pattern as idle-resource-cleanup.
- **`terraform test` test suites** per module — the only structural gap
  v0.2.1 leaves open.

See per-module `CHANGELOG.md` and the framework-level
[CHANGELOG.md](../CHANGELOG.md) for the detailed history.

---

## Decision framework — should we adopt this?

Three honest answers, depending on context:

- **You already have Cloudability / Apptio.** Adopt. The framework's
  *execution + enforcement + audit* surface complements analytics
  cleanly. See `examples/cloudability-complement` for the canonical
  composition.
- **You have neither Cloudability nor a budget for it.** Adopt + use
  the framework's Athena named-queries library + CloudWatch dashboards
  as your interim analytics layer. Pay for a commercial tool when your
  cross-account / multi-cloud needs outgrow what Athena can do.
- **You have a sub-$50k/month cloud bill.** The framework is overkill;
  AWS native (Budgets, Cost Explorer, Compute Optimizer, Cost
  Anomaly Detection — all free or near-free) is enough for now. Adopt
  this framework once you cross $100k/mo and either tagging discipline
  becomes a blocker or non-prod scheduling becomes worth automating.

---

## Where to dig deeper

| Question | Where to look |
|---|---|
| How is it architected? | [ARCHITECTURE.md](ARCHITECTURE.md) |
| What's the security posture? | [THREAT_MODEL.md](THREAT_MODEL.md) + [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md) |
| How much will it cost in our account? | [COST_ESTIMATE.md](COST_ESTIMATE.md) |
| What happens when something breaks? | [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md) + [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) |
| What does each metric mean? | [METRICS_GLOSSARY.md](METRICS_GLOSSARY.md) |
| How do we get started? | [GETTING_STARTED.md](GETTING_STARTED.md) → [PHASES.md](PHASES.md) → `examples/minimal` |

Maintainer: Ivan Kovtun. Contributing: see [CONTRIBUTING.md](../CONTRIBUTING.md).
