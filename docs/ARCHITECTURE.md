# Architecture

This framework is organized around the [FinOps Foundation Capabilities](https://www.finops.org/framework/capabilities/). Each module implements one or more named Capabilities; the root composition wires them together via a shared events bus and a shared KMS CMK.

## Aligning to the FinOps Foundation Framework

The FinOps Foundation Framework groups Capabilities into six **domains**. The table below shows which modules sit in which domain, and what the framework actually delivers for each.

| Domain | Capability | Module(s) | What this framework produces |
|---|---|---|---|
| **Understand cloud usage and cost** | Data Ingestion & Normalization | `cost-data-exports` | CUR 2.0 + FOCUS 1.0 in S3, partitioned, Athena-queryable |
| | Allocation | `cost-categories`, `tag-governance` | Cost Categories as code; required-tag enforcement |
| | Reporting & Analytics | `cost-data-exports`, `finops-metrics` | Athena workgroup; standard KPI views + custom metrics |
| | Anomaly Management | `anomaly-detection` | Service-level Cost Anomaly Detection → events bus |
| **Quantify business value** | Forecasting | (Cost Explorer + budgets) | Forecast notifications via `budgets`; Cost Explorer native forecasts |
| | Budgeting | `budgets` | Polymorphic budgets (account/service/tag/cost_category) |
| | Benchmarking | `finops-metrics` | Named KPIs (allocation coverage %, commitment coverage %, etc.) |
| | Unit Economics | `finops-metrics` + `cost-categories` | Cost-per-allocation-unit Athena view |
| **Optimize cloud usage and cost** | Architecting for Cloud | `optimization-services` | Compute Optimizer surfaces rightsizing recs |
| | Rate Optimization | `savings-coverage-reporter` | Weekly RI/SP coverage & utilization |
| | Workload Optimization | `idle-resource-cleanup`, `instance-scheduler` | Idle-resource flagging (dry-run); tag-driven start/stop |
| | Cloud Sustainability | (Cost Optimization Hub) | Surfaced via `optimization-services` |
| **Manage the FinOps practice** | Policy & Governance | `tag-governance` | Required-tag Config rules + EventBridge → events bus |
| | FinOps Practice Operations | (the framework itself) | The events bus, alarms, audit trail are the operational backbone |
| | FinOps Education | — | Out of scope for code |
| | Onboarding Workloads | — | Out of scope; handle via IaC patterns |
| **Embed FinOps** | Chargeback & IT Finance Integration | `cost-categories` + `finops-metrics` | Cost Category ARNs as join keys; KPIs in CloudWatch/SSM |
| | Invoicing & Billing | — | Out of scope; downstream of allocation |
| | FinOps Tools & Services | — | The framework itself |
| | Intersecting Disciplines | — | Plug into your security/data/sustainability programs |

## Data flow

```
                          ┌─────────────────────────┐
                          │   AWS Billing Service   │
                          └──────────┬──────────────┘
                                     │ writes
                                     ▼
   ┌─────────────────────────────────────────────────────────────┐
   │   cost-data-exports module                                  │
   │   ┌─────────────┐   ┌──────────────┐   ┌─────────────────┐ │
   │   │   CUR 2.0   │   │  FOCUS 1.0   │   │  S3 bucket      │ │
   │   │   export    │──▶│    export    │──▶│  (KMS-encrypted)│ │
   │   └─────────────┘   └──────────────┘   └────────┬────────┘ │
   │                                                  │          │
   │                          ┌───────────────────────┘          │
   │                          ▼                                  │
   │                   ┌──────────────┐                          │
   │                   │   Athena WG  │◀── Glue catalog          │
   │                   │  + database  │                          │
   │                   └──────┬───────┘                          │
   └──────────────────────────┼──────────────────────────────────┘
                              │ queried by
                              ▼
       ┌──────────────────────────────────────────────────┐
       │  finops-metrics module                           │
       │  - Named Athena KPI views                        │
       │  - Aggregator Lambda → CloudWatch + SSM          │
       └──────────────────────────────────────────────────┘
                              ▲
                              │ joins
                              │
   ┌──────────────────────────┴───────────────┐
   │  Cost Categories (allocation as code)    │
   │  - BusinessUnit, RegulatoryScope, ...    │
   └──────────────────────────────────────────┘


   ┌─────────────────────────────────────────────────────────────────┐
   │                    Events bus (SNS, KMS-encrypted)              │
   │                                                                 │
   │   ┌────────────┐    Email subscribers                          │
   │   │            │◀───────────                                    │
   │   │ SNS Topic  │                                                │
   │   │  (CMK)     │───▶┌─────────────────────┐                     │
   │   │            │    │ Chat Notifier Lambda │───▶ Slack / Teams  │
   │   └─────▲──────┘    │ (Secrets Manager)   │                     │
   └─────────┼───────────┴─────────────────────┴────────────────────┘
             │ publishes
             │
   ┌─────────┴──────┬─────────────────┬────────────────────┬───────────────┐
   │                │                 │                    │               │
   ▼                ▼                 ▼                    ▼               ▼
 Budgets    Anomaly Detection    Tag Governance    Idle Cleanup    Coverage Reporter
 - acct     - Service monitor    - Config rule     - EBS Lambda    - RI/SP Lambda
 - service                       - EventBridge     - EIP Lambda    (DLQ + alarms)
 - tag      Forecast actions     - Lambda alarms   - Snapshot      KPI emission
 - cat      DLQ + alarms         DLQ + alarms      Lambda (DLQ +   to events bus
            forecast accuracy                      alarms)         and finops-metrics
```

## Module dependency graph

```
alerting          ← root (created first; everyone needs events_topic_arn)
   ↑
   ├── budgets                (also depends_on cost_categories for cost_category-scoped budgets)
   ├── anomaly-detection
   ├── tag-governance
   ├── idle-resource-cleanup
   ├── instance-scheduler
   ├── savings-coverage-reporter
   └── finops-metrics        (also depends on cost-data-exports + cost-categories for KPI views)

cost-data-exports ← depends on kms only
cost-categories   ← independent (rule data only)
optimization-services ← independent (account-level enrollment)
```

## What lives OUTSIDE this framework

By design, the framework does NOT include:

- **A FinOps dashboard or BI tool.** Output is structured data (CUR, Cost Categories, KPI Athena views, CloudWatch metrics, SSM parameters). Plug it into QuickSight, Power BI, Looker, Tableau, or CloudHealth.
- **The chargeback ledger itself.** Cost Categories produce the allocation logic; your finance system books the journal entries.
- **Anything that touches production data without explicit opt-in.** Idle cleanup is dry-run by default. Instance scheduler is opt-in by tag.
- **Tag remediation that mutates resources.** AWS Config could be configured to auto-tag; the framework deliberately doesn't, for the reasons documented in [modules/tag-governance/README.md](../modules/tag-governance/README.md).
- **Multi-account / org-management primitives.** SCPs, Tag Policies, and payer-account anomaly monitoring are out of scope — handle those in your landing-zone / org-management workspace.

## Failure modes and how the framework handles them

| Failure | Behaviour |
|---|---|
| CUR delivery fails | S3 bucket policy logs the rejection; no impact on other modules. Re-run terraform apply to re-validate. |
| SNS delivery fails | Subscriptions retry per AWS defaults; failed deliveries log to CloudWatch. |
| Lambda execution fails | Exception logs to CloudWatch (CMK-encrypted, configurable retention). Failed async invocations land in the per-Lambda SQS DLQ (14-day retention). Two CloudWatch alarms fire to the events topic: `Lambda Errors` and `DLQ ApproximateNumberOfMessagesVisible`. |
| KMS key rotation | The framework's CMK has automatic rotation enabled. No action needed. |
| Cost Explorer API throttling | `savings-coverage-reporter` re-runs next week. Manual invocation possible. |
| Athena query failures | Workgroup-level CloudWatch metrics. The framework provisions only the workgroup; user-driven query failures are between the user and Athena. |
| `finops-metrics` aggregator fails | Lambda alarm fires; KPI values in CloudWatch/SSM go stale until next successful run. Last-known-good values remain readable. |
