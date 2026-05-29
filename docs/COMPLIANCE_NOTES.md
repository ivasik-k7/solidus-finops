# Audit-Friendly Evidence Guide

This document explains what evidence the framework produces and maps that evidence to common regulatory control families. **Most accounts won't be subject to all of these regimes** — read only the sections relevant to your workload. The framework's audit-friendliness comes from its design (immutable cost data, allocation as code, KMS everywhere) and applies regardless of whether you're regulated; the regulatory mapping is a convenience for those who are.

This is intended to support audit conversations, not to constitute legal compliance advice.

## How any reviewer should use this framework

When someone — internal finance, an auditor, a regulator — asks "show me how you allocate cloud spend to teams / BUs / products," the answer is the combination of:

1. **The git repository** containing `modules/cost-categories/main.tf` and the root `cost_categories` variable definition. This is the **rule set**.
2. **The CloudTrail log** showing the `CreateCostCategoryDefinition` and `UpdateCostCategoryDefinition` API calls. This is **proof of when the rules took effect**.
3. **The CUR S3 bucket** containing 7 years of usage data. This is the **input**.
4. **The Athena workgroup** containing query history. This is the **output evidence**.

The chain is fully reproducible: an auditor can re-run any historical month's allocation by checking out the relevant git SHA, querying the CUR data with the matching cost-category definitions, and getting the same numbers.

## Control mapping

The sections below cover the regimes most often asked about. Skip any that don't apply to your account. The framework doesn't change behavior based on which regime you're under — these mappings just point auditors at the right evidence.

### SOX (Sarbanes-Oxley) — applies to public companies in the US

| Control area | Framework artifact |
|---|---|
| ITGC: Change management | All changes to `cost-categories` and `tag-governance` go through TFE plan/apply with audit trail in TFE and git |
| ITGC: Access management | TFE workspace RBAC + AWS IAM least-privilege per Lambda |
| ITGC: Logical security | KMS encryption on all data at rest; TLS-only S3 bucket policy |
| Financial reporting accuracy | Cost Categories + amortized CUR provide reproducible allocation; 7-year retention satisfies SOX records requirement |

### PCI DSS — applies if cardholder data touches AWS

| Requirement | Framework artifact |
|---|---|
| 3.5 (Protect cryptographic keys) | Framework KMS CMK with key rotation enabled; key policy restricts access; chat webhooks stored in Secrets Manager (CMK-encrypted) rather than Lambda env vars |
| 7 (Least privilege) | Each Lambda has its own IAM role with action-specific permissions; Secrets Manager access scoped to specific secret ARNs via `compact()` |
| 10 (Logging) | All Lambdas log to CloudWatch with 7-year CMK-encrypted retention. Account-level CloudTrail (configured separately) captures KMS, S3, Secrets Manager, Cost Explorer API calls. |
| 10.5 (Protect audit trails) | CloudWatch log groups are CMK-encrypted; log retention enforced by Terraform; `prevent_destroy` on KMS key and cost-data buckets |
| 12.10.1 (Incident response) | Events SNS topic routes anomalies to on-call channels; every Lambda has a DLQ + error alarm so silent failures are surfaced |

### GDPR — applies to EU customer data

| Article | Framework artifact |
|---|---|
| 5 (Data minimization) | Cost data does NOT contain customer PII. CUR contains only resource IDs and tags, which should themselves be free of PII per your tagging policy. |
| 32 (Security of processing) | KMS encryption; TLS-only bucket policy; Secrets Manager for chat webhooks |
| Recital 49 (region selection) | The framework deploys to a single configured region (`var.aws_region`). Region restrictions across the account are out of scope — enforce via SCPs or AWS Config rules in your org-management workspace. |

### DORA — applies to EU financial entities since January 2025

| Article | Framework artifact |
|---|---|
| 6 (ICT risk framework) | The framework itself is an ICT control; documented in this repo |
| 8 (Identification of ICT risks) | Cost anomalies surface unexpected usage patterns that may indicate operational issues |
| 16 (ICT incident management) | Events SNS topic integrates with incident response channels; per-Lambda DLQs preserve failed events for forensic analysis |
| 28 (ICT third-party risk) | Cost categories can be defined per third-party SaaS for visibility |

### BCBS 239 — Principles for risk data aggregation

| Principle | Framework artifact |
|---|---|
| 3 (Accuracy and integrity) | Single source of truth (CUR); allocation logic in code; no manual spreadsheet allocation |
| 4 (Completeness) | All AWS services covered by CUR; tag coverage tracked by Config rule |
| 5 (Timeliness) | CUR updated multiple times per day; anomaly detection runs continuously |
| 6 (Adaptability) | Framework is modular; new dimensions added as Cost Categories |
| 11 (Distribution) | Events SNS topic fans out to chat (Slack/Teams), email, and any other subscriber |

### Internal audit and regulator data requests

The framework supports the following auditor scenarios:

**"Reproduce the September 2024 allocation for Investment Banking."**
1. `git checkout <commit that was current on 2024-09-30>`
2. Read `cost-categories` definition for `BusinessUnit`.
3. Query CUR for September 2024 partitions.
4. Filter where `cost_category[BusinessUnit] = 'investment-banking'`.
5. Aggregate unblended cost (and amortized cost separately for committed-spend allocation).
6. Result is reproducible to the cent.

**"Show me every action that modified the Cost Category for BusinessUnit since the start of the year."**
1. CloudTrail → filter on `eventName = UpdateCostCategoryDefinition` and the specific category ARN.
2. Each event has the IAM principal, source IP, request payload, response.
3. Cross-reference with TFE run history to see which PR / approver authorized each change.

**"Show me how data residency is enforced."**
1. This framework provisions only in `var.aws_region`. The bucket and KMS key live there; CUR uses an us-east-1 provider alias because the AWS billing API only exists there (data still lands in the bucket in your primary region).
2. Account-wide region restriction is **out of scope for this framework** — enforce via SCPs / AWS Config managed rules in your org-management workspace.
3. CloudTrail records any denial events from those enforcement layers.

## What the framework does NOT do

It is important to be explicit about what the framework does and does not cover:

- **It does NOT make you compliant by itself.** Compliance is an organizational outcome; this framework provides supporting evidence.
- **It does NOT enforce SCPs.** SCPs are organization-level and must be applied via your org-management workspace.
- **It does NOT encrypt the FinOps team's BI tool credentials.** Whatever you use to consume Athena (QuickSight, Power BI, etc.) has its own security boundary.
- **It does NOT validate the correctness of allocation rules.** If your `cost-categories` definition has a typo, it will faithfully allocate to the typo'd value. Peer review on PRs is the mitigation.

## Periodic compliance activities

Recommended audit-cycle activities supported by the framework:

| Frequency | Activity | Framework support |
|---|---|---|
| Daily | Anomaly review | `anomaly-detection` → SNS → on-call channel |
| Weekly | Idle resource review | `idle-resource-cleanup` SNS digest |
| Weekly | RI/SP coverage review | `savings-coverage-reporter` SNS digest |
| Monthly | Budget vs. actual review | `budgets` alerts + Cost Explorer |
| Monthly | Chargeback close | Athena query against CUR + cost categories |
| Quarterly | Tag compliance review | `tag-governance` Config rule history |
| Quarterly | Commitment review (RI/SP refresh) | Coverage report deltas |
| Annually | Cost category review with finance | Cost Categories git history |
| Annually | Framework Terraform module review | Repo PR history |
