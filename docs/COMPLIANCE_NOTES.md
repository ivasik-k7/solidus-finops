# Audit-Friendly Evidence Guide — Solidus FinOps

This document explains what evidence Solidus FinOps produces and maps that
evidence to common regulatory control families. **Most accounts won't be
subject to all of these regimes** — read only the sections relevant to
your workload. The framework's audit-friendliness comes from its design
(immutable cost data, allocation as code, DDB STATE+ACTION audit rows on
every mutation, KMS everywhere) and applies regardless of whether you're
regulated; the regulatory mapping is a convenience for those who are.

This is intended to support audit conversations, not to constitute legal
compliance advice.

## How any reviewer should use Solidus FinOps

When someone — internal finance, an auditor, a regulator — asks "show me
how you allocate cloud spend to teams / BUs / products," the answer is
the combination of:

1. **The git repository** containing the root `tag_governance_required_tags`
   + `tag_governance_taxonomy` variable definitions. This is the **rule
   set** for what every resource must be tagged with.
2. **The CloudTrail log** showing every `aws_config_config_rule`,
   `aws_resourcegroups_group`, and `aws_lambda_function` change. This is
   **proof of when the rules took effect**.
3. **The CUR S3 bucket** containing up to 7 years of usage data. This is
   the **input**.
4. **The Athena workgroup** containing query history. This is the
   **output evidence** — every dollar can be re-derived by re-running the
   query on the historical CUR.
5. **The DDB audit tables** (`<prefix>-scheduler-state`,
   `<prefix>-idle-findings`, `<prefix>-kpi-snapshots`, etc.) containing
   STATE + ACTION rows for every framework-driven mutation. This is the
   **action ledger** — who/what/when/why for every Lambda action.

The chain is fully reproducible: an auditor can re-run any historical
month's allocation by checking out the relevant git SHA, querying the
CUR data with the matching tag rules and Athena named queries (also
committed), and getting the same numbers.

## Control mapping

The sections below cover the regimes most often asked about. Skip any
that don't apply to your account. The framework doesn't change behaviour
based on which regime you're under — these mappings just point auditors
at the right evidence.

### SOX (Sarbanes-Oxley) — applies to public companies in the US

| Control area | Framework artifact |
|---|---|
| ITGC: Change management | All changes to `tag_governance_*` + `budgets_items` + `finops_metrics_custom_kpis` go through TFE plan/apply with audit trail in TFE and git |
| ITGC: Access management | TFE workspace RBAC + AWS IAM least-privilege per Lambda; conditional `sns:Publish` only when `events_topic_arn` is set |
| ITGC: Logical security | KMS encryption on all data at rest; TLS-only S3 bucket policy; webhooks in Secrets Manager not env vars |
| Financial reporting accuracy | Tag-driven allocation + 7-year CUR retention + DDB action audit logs satisfy SOX records requirements |

### PCI DSS — applies if cardholder data touches AWS

| Requirement | Framework artifact |
|---|---|
| 3.5 (Protect cryptographic keys) | Framework KMS CMK with key rotation enabled; key policy restricts access; chat webhooks stored in Secrets Manager (CMK-encrypted) rather than Lambda env vars |
| 7 (Least privilege) | Each Lambda has its own IAM role with action-specific permissions; SNS publish gated by `concat()` (only present when wired to an events topic); SSM and DDB permissions scoped to specific ARNs |
| 10 (Logging) | All Lambdas log to CloudWatch with up-to-7-year CMK-encrypted retention. Account-level CloudTrail (configured separately) captures KMS, S3, Secrets Manager, Cost Explorer API calls. DDB ACTION rows have a 7-year TTL by default. |
| 10.5 (Protect audit trails) | CloudWatch log groups are CMK-encrypted; log retention enforced by Terraform; `prevent_destroy` on KMS key, cost-data bucket, and the audit DDB tables; DDB PITR enabled |
| 12.10.1 (Incident response) | Events SNS topic routes alerts to severity-filtered channels via the dispatcher Lambda (Slack / Teams / PagerDuty / Opsgenie). Every Lambda has a DLQ + error alarm + DLQ-depth alarm so silent failures are surfaced. |

### GDPR — applies to EU customer data

| Article | Framework artifact |
|---|---|
| 5 (Data minimization) | Cost data does NOT contain customer PII. CUR contains only resource IDs and tags, which should themselves be free of PII per your tagging policy. The `tag_governance_taxonomy` lets you mark which tags are operational vs. allocation vs. compliance so a reviewer can see at a glance what each tag means. |
| 32 (Security of processing) | KMS encryption; TLS-only bucket policy; Secrets Manager for chat webhooks; DDB tables encrypted with the framework CMK |
| Recital 49 (region selection) | The framework deploys to `var.aws_primary_region` + `var.aws_secondary_regions`. Region restrictions across the account are out of scope — enforce via SCPs or AWS Config rules in your org-management workspace. |

### DORA — applies to EU financial entities since January 2025

| Article | Framework artifact |
|---|---|
| 6 (ICT risk framework) | Solidus FinOps itself is an ICT control; documented in this repo |
| 8 (Identification of ICT risks) | `finops-metrics` ForecastAbsDriftPct + per-KPI WoW-drift alarms surface unexpected usage patterns that may indicate operational issues |
| 16 (ICT incident management) | Events SNS topic integrates with the multi-channel dispatcher; per-Lambda DLQs preserve failed events for forensic analysis; the dispatcher's own audit-log DDB table records every dedup decision and every channel delivery |
| 28 (ICT third-party risk) | Budgets can be scoped per service or per BusinessUnit tag (= per third-party SaaS) for visibility |

### BCBS 239 — Principles for risk data aggregation

| Principle | Framework artifact |
|---|---|
| 3 (Accuracy and integrity) | Single source of truth (CUR); allocation logic in code; no manual spreadsheet allocation; DDB ACTION rows are append-only |
| 4 (Completeness) | All AWS services covered by CUR; tag coverage tracked by Config rule + dollarised by `tag-governance` untagged-cost report |
| 5 (Timeliness) | CUR updated multiple times per day; `finops-metrics` aggregator runs daily; `cost-data-exports` health-check Lambda flags freshness gaps |
| 6 (Adaptability) | Framework is modular; new KPIs added via `finops_metrics_custom_kpis`; new tag dimensions via `tag_governance_taxonomy` |
| 11 (Distribution) | Events SNS topic fans out to chat (Slack / Teams / PagerDuty / Opsgenie), email, generic webhooks, and SQS — all with severity routing and dedup |

### Internal audit and regulator data requests

The framework supports the following auditor scenarios:

**"Reproduce the September 2024 allocation for Investment Banking."**
1. `git checkout <commit that was current on 2024-09-30>`
2. Read the `tag_governance_required_tags` + `tag_governance_taxonomy` definitions.
3. Query CUR for September 2024 partitions via the Athena workgroup.
4. Filter where `resource_tags['user_BusinessUnit'] = 'investment-banking'`.
5. Aggregate unblended cost (and amortized cost separately for committed-spend allocation).
6. Result is reproducible to the cent.

**"Show me every action the framework took on resource i-0abc1234 in the last 6 months."**
1. Query the relevant DDB audit table (`<prefix>-scheduler-state` for instance-scheduler actions, `<prefix>-idle-findings` for cleanup actions).
2. `Query` with `PK = "EC2#i-0abc1234"`, range over `SK` for ACTION rows.
3. Each row contains action type, schedule name, actor (Lambda function ARN), timestamp, and notes.

**"Show me every framework action on a given date across the fleet."**
1. For `instance-scheduler`: query the `ActionsByDate` GSI where `GSI1PK = "ACTION#2026-05-29"`.
2. For other modules: scan the audit table with `SK BeginsWith "ACTION#2026-05-29"` (use sparingly — consider adding a GSI in a future version).

**"Show me how data residency is enforced."**
1. Framework infrastructure (KMS, DDB, Lambdas, dashboards) lives in `var.aws_primary_region`. Scanning Lambdas iterate `var.aws_secondary_regions` if you've configured them.
2. The cost-data bucket and KMS key live in the primary region; CUR uses a us-east-1 provider alias because the AWS billing API only exists there (data still lands in the bucket in your primary region).
3. Account-wide region restriction is **out of scope for this framework** — enforce via SCPs / AWS Config managed rules in your org-management workspace.
4. CloudTrail records any denial events from those enforcement layers.

## What the framework does NOT do

It is important to be explicit about what Solidus FinOps does and does
not cover:

- **It does NOT make you compliant by itself.** Compliance is an organizational outcome; the framework provides supporting evidence.
- **It does NOT enforce SCPs.** SCPs are organization-level and must be applied via your org-management workspace.
- **It does NOT encrypt the FinOps team's BI tool credentials.** Whatever you use to consume Athena or the framework's outputs (QuickSight, Power BI, Cloudability, Tableau) has its own security boundary.
- **It does NOT validate the correctness of allocation rules.** If your `tag_governance_required_tags` list has a typo or your `finops_metrics_custom_kpis` SQL has a bug, it will faithfully apply that typo / bug. Peer review on PRs is the mitigation.
- **It does NOT model Cost Categories as Terraform resources.** AWS Cost Categories are useful but the framework treats allocation as a *tagging* problem (one tag, one rule, one PR). If you need Cost Categories for Cloudability's Business Mappings, define them outside the framework.

## Periodic compliance activities

Recommended audit-cycle activities supported by the framework:

| Frequency | Activity | Framework support |
|---|---|---|
| Daily | KPI drift review (absolute + WoW) | `finops-metrics` CloudWatch alarms → events bus → dispatcher → on-call |
| Daily | Anomaly review | Cost Explorer console + `AnomalyImpactUsdMtd` KPI |
| Daily | Budget burn-rate + adherence | `budgets` performance Lambda → dashboard |
| Weekly | Idle resource review | `idle-resource-cleanup` digest |
| Weekly | Scheduler discovery review | `instance-scheduler` weekly discovery Lambda |
| Weekly | Untagged-cost review | `tag-governance` Athena-driven dollarisation |
| Monthly | Budget vs. actual review | `budgets` adherence score + dashboard |
| Monthly | Chargeback close | DDB KPI snapshots + Athena over CUR |
| Quarterly | Tag compliance review | `tag-governance` Config rule history + DDB action audit |
| Quarterly | Commitment renewal | `CommitmentCoveragePct` + `CommitmentUtilizationPct` trend |
| Annually | Tag taxonomy review with finance | git history on `tag_governance_taxonomy` |
| Annually | Framework module upgrade | Repo PR history; per-module CHANGELOG files |
