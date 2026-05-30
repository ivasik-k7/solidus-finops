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

## Documented Checkov suppressions

### Current static-analysis posture (as of v0.2.1)

| Check | Status |
|---|---|
| `terraform fmt -recursive` | ✅ Clean |
| `terraform validate` — root + every example | ✅ Clean |
| `tflint --recursive --format compact` | ✅ **0 issues** |
| **Checkov** (run in CI with `soft_fail: false`) | ✅ **0 unsuppressed failings** |
| Python AST parse — every Lambda source | ✅ Clean |

CI enforces all of the above — a PR that introduces a new Checkov
finding without an inline `# checkov:skip=` comment **fails the build**
and cannot merge. This document is the audit-grade index of every
suppression that exists, why it exists, and where it lives in code.

### How to read this section

Every Checkov rule the framework suppresses has:

1. **An inline `# checkov:skip=<rule>:<reason>` comment** on the
   affected resource, with the rationale written out.
2. **A subsection below** linking the rule, the resources, the why,
   the mitigation, and (where applicable) the AWS docs page that
   justifies it.

Suppressions split into three categories:

- **AWS-imposed limitations** — actions whose IAM model doesn't accept
  resource-level permissions, services that don't expose rotation APIs,
  etc. The framework can't work around AWS.
- **Design decisions** — patterns the framework deliberately doesn't
  implement because there's a better in-AWS solution (CloudTrail data
  events instead of per-bucket S3 access logging, e.g.).
- **Static-analyser false positives** — controls that ARE configured
  but Checkov 3.x doesn't trace through Terraform's
  `aws_s3_bucket_*` companion-resource pattern. Run `terraform plan`
  to see the linked resources.

Each subsection below states which category it falls into.

### CKV_AWS_272 — Lambda code-signing validation

**Status:** suppressed on every `aws_lambda_function` in the framework
(8 resources across 7 modules).

**Why:** Code-signing validation requires AWS Signer infrastructure —
a signing profile, a signing configuration, and a signing pipeline
(typically CodePipeline). It's an enterprise-grade supply-chain
control that's almost never needed for an in-house FinOps framework.

**Mitigation:** Consumers should pin the framework's Terraform module
source to a specific git tag or commit SHA (e.g.
`source = "git::https://.../...?ref=v0.2.1"`), making supply-chain
attacks visible as a state change in the next `terraform plan`. The
framework's CI also includes a `terraform validate` + lint pass on every
PR, so unreviewed code can't merge to `main`.

**To enable code-signing in your deployment:** fork the relevant
module, add an `aws_signer_signing_profile` + `aws_signer_signing_job`
+ `code_signing_config_arn` block referencing the published `.zip`'s
signed object, and remove the `# checkov:skip=CKV_AWS_272` line.

### CKV_AWS_286, CKV_AWS_288, CKV_AWS_289 — Budget Actions IAM role

**Status:** suppressed on `modules/budgets/main.tf`
`aws_iam_role_policy.budget_actions`.

**Why:** AWS Budget Actions is a managed service that performs IAM
attach/detach, EC2 stop, RDS stop, SSM Automation, and
Organizations:AttachPolicy actions on the **caller's behalf** when a
budget threshold is breached. The IAM role trust policy restricts
`AssumeRole` to **only** `budgets.amazonaws.com` (the AWS Budgets
service principal). The role itself requires exactly the permissions
AWS documents as required for Budget Actions; the target resources
(which IAM policy, which EC2 instance, which Org account) are chosen
**at runtime** by the AWS Budgets service from each budget's `actions`
configuration — Terraform can't constrain them at provision time.

**Mitigation:**

- Trust policy is the only effective guard, and it's tight: only
  `budgets.amazonaws.com` can assume the role.
- The Budget Actions service itself reads the budget config to decide
  what to do; it cannot freelance.
- Every Budget Action execution is logged to CloudTrail.

**AWS reference:** [Configuring AWS Budget Actions — IAM permissions](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html)

### CKV_AWS_288 — Athena/Glue read access in tag-governance

**Status:** suppressed on
`modules/tag-governance/main.tf` `aws_iam_role_policy.untagged_cost`.

**Why:** The untagged-cost Lambda runs an Athena query against the CUR
table to dollarize the tag gap. Athena's `StartQueryExecution` +
`GetQueryResults` and Glue's `GetDatabase` / `GetTable` /
`GetPartitions` do not support resource-level permissions per the AWS
Service Authorization Reference. S3 access for query results is
required for Athena to function at all.

**Mitigation:** the Lambda has read-only intent (no writes outside the
Athena results bucket), KMS-encrypts its query results, and is
schedule-triggered only (no public invoke path).

### CKV_AWS_290 — IAM allows write access without constraints

**Status:** suppressed on `modules/instance-scheduler/iam.tf`
(scheduler role), `modules/idle-resource-cleanup/main.tf` (per-Lambda
roles), and the two IAM policies above.

**Why:** Several AWS actions the framework needs do not accept
resource-level permissions. Specifically:

- `ec2:StartInstances`, `ec2:StopInstances`
- `rds:StartDBInstance`, `rds:StopDBInstance`,
  `rds:StartDBCluster`, `rds:StopDBCluster`
- `autoscaling:UpdateAutoScalingGroup`,
  `autoscaling:CreateOrUpdateTags`, `autoscaling:DeleteTags`
- `ec2:DeleteVolume`, `ec2:DeleteSnapshot`,
  `ec2:ReleaseAddress`, `ec2:DeleteNatGateway`,
  `ec2:DeleteNetworkInterface`
- `elasticloadbalancing:DescribeLoadBalancers`,
  `elasticloadbalancing:DeleteLoadBalancer`

These actions require `Resource = "*"`. See the
[AWS Service Authorization Reference for EC2](https://docs.aws.amazon.com/service-authorization/reference/list_amazonec2.html)
and the corresponding pages for RDS, ASG, and ELB.

**Mitigation:** scope is enforced inside the Lambda runtime instead of
in IAM:

- `instance-scheduler` only acts on resources tagged with the
  `OPT_IN_TAG_KEY` (default `Schedule`). Untagged resources are
  filtered out before any AWS mutation.
- `idle-resource-cleanup` defaults to `dry_run = true` and respects
  the `EXCEPTION_TAG_KEY` (default `FinOpsException`). Production
  resources tagged with this key are never acted on.
- Both modules cap blast radius via `max_actions_per_tick` / aging
  thresholds + DDB STATE+ACTION audit rows for every action.

### CKV_AWS_355 — IAM `Resource = "*"` for restrictable actions

**Status:** same locations + same rationale as CKV_AWS_290.

This rule is a stricter restatement of CKV_AWS_290. The suppressions
share the same justification: AWS-imposed limitation on resource-level
permissions for the EC2 / RDS / ASG / ELB actions the framework needs.

### CKV_AWS_18 — S3 access logging

**Status:** suppressed on all three framework-managed S3 buckets:
`cost-data-exports/aws_s3_bucket.cost_data`,
`cost-data-exports/aws_s3_bucket.athena_results`, and
`tag-governance/aws_s3_bucket.config`.

**Why:** S3 access logging duplicates information CloudTrail S3 data
events provide more thoroughly. Recommended pattern: enable CloudTrail
data events at the AWS Organizations level so audit logging is
centrally managed, not per-bucket. The framework's role is to provision
the buckets; org-level CloudTrail is out of scope (it's typically
configured in the landing-zone / Control Tower workspace).

**Mitigation:** the buckets are KMS-encrypted, have public-access
block, `prevent_destroy = true`, and a TLS-only bucket policy.
CloudTrail (configured separately) records every API call against
them, satisfying the audit-grade access-log requirement.

### CKV_AWS_144 — S3 cross-region replication

**Status:** suppressed on all three buckets.

**Why:** CRR is overkill for the framework's three buckets:

- **cost_data** holds CUR — AWS can regenerate any historical month's
  CUR on request. The bucket is a durable read replica, not the
  authoritative source.
- **athena_results** is ephemeral (30-day lifecycle); results
  regenerate on re-query.
- **config** is AWS Config history — Config can replay the timeline
  from CloudTrail if the bucket is destroyed.

CRR would double storage cost without proportional audit value. Orgs
that need DR-grade replication for cost data can layer it on top by
adding `aws_s3_bucket_replication_configuration` outside the module.

### CKV2_AWS_62 — S3 event notifications

**Status:** suppressed on all three buckets.

**Why:** None of the three buckets need event-driven downstream
processing:

- **cost_data**: CUR delivery follows AWS's schedule; the framework's
  daily health-check Lambda probes freshness on a fixed cron.
- **athena_results**: query results are read synchronously by
  whatever issued the query — there's no async consumer.
- **config**: AWS Config delivers on its own cadence; the
  tag-governance EventBridge listener watches `aws.config`, not the
  bucket directly.

### CKV2_AWS_57 — Secrets Manager automatic rotation

**Status:** suppressed on all five
`aws_secretsmanager_secret.<channel>` resources in `alerting`
(`slack`, `teams`, `pagerduty`, `opsgenie`, `webhook`).

**Why:** The secrets hold webhook URLs and integration keys for
**third-party services** that don't expose rotation APIs:

- **Slack / Teams webhook URLs** are immutable; the workspace admin
  must regenerate them via the third-party UI.
- **PagerDuty / Opsgenie integration keys** are static credentials
  managed in their respective UIs.
- **Generic webhooks** are caller-defined opaque strings; the
  framework has no knowledge of how to rotate them.

Secrets Manager rotation is a Lambda-driven workflow that requires the
target service to accept programmatic credential updates — none of
these do.

**Mitigation:** secrets are CMK-encrypted, recovery window 30 days,
access scoped to the dispatcher Lambda role only. Operators rotate
manually when the upstream third party rotates.

### CKV2_AWS_45 + CKV2_AWS_48 — AWS Config recorder

**Status:** suppressed on
`tag-governance/aws_config_configuration_recorder.main` (CKV2_AWS_48)
and `aws_config_configuration_recorder_status.main` (CKV2_AWS_45).

**Why:** Checkov 3.x false-positives:

- **CKV2_AWS_48** requires `recording_group.all_supported = true` AND
  `include_global_resource_types = true`. The framework sets
  `all_supported = true` literally; `include_global_resource_types`
  is controlled by `var.record_global_resources` (default `true`).
  Checkov can't see the variable's default, so it flags as missing.
- **CKV2_AWS_45** requires `is_enabled = true` on the
  recorder-status resource — which is set literally. The rule
  false-flags when `count` is used on the resource.

**Mitigation:** the configuration is correct by inspection of the
literal HCL; deployments with the default variable values record
every supported AWS resource type, including global types.

### Checkov false positives on S3 companion-resource indirection

**Status:** suppressed on `cost-data-exports/aws_s3_bucket.athena_results`
and `tag-governance/aws_s3_bucket.config`.

**Why:** Checkov 3.x sometimes fails to associate the linked S3
configuration resources (`aws_s3_bucket_versioning`,
`aws_s3_bucket_server_side_encryption_configuration`,
`aws_s3_bucket_public_access_block`, `aws_s3_bucket_lifecycle_configuration`)
with their parent bucket and false-flags the bucket itself as missing
those features. The companion resources DO exist alongside the bucket
in the same module:

| Rule | Suppressed | Companion resource that proves the control is present |
|---|---|---|
| CKV_AWS_21 (versioning) | athena_results, config | `aws_s3_bucket_versioning.athena_results`, `.config` |
| CKV_AWS_145 (KMS) | athena_results, config | `aws_s3_bucket_server_side_encryption_configuration.athena_results`, `.config` |
| CKV2_AWS_6 (public access block) | athena_results, config | `aws_s3_bucket_public_access_block.athena_results`, `.config` |
| CKV2_AWS_61 (lifecycle) | athena_results, config | `aws_s3_bucket_lifecycle_configuration.athena_results`, `.config` |

Run `terraform plan` to see the linked resources for yourself; the
controls are real.

### Workflow-level Checkov skips

In addition to the inline `# checkov:skip=` suppressions documented
above, three rules are suppressed at the **CI workflow level** in
[.github/workflows/terraform-ci.yml](../.github/workflows/terraform-ci.yml)
because they're framework-wide patterns rather than per-resource
decisions:

| Rule | Why skipped at workflow level |
|---|---|
| **CKV_AWS_111** — IAM wildcards in actions | The framework's EC2/RDS/ASG actions (`StartInstances`, `StopInstances`, `Describe*`) don't accept resource-level permissions per the AWS Service Authorization Reference. Already covered for specific roles by the inline suppressions of CKV_AWS_290 / 355; this is the workflow-level companion. |
| **CKV2_AWS_5** — Security Groups attached to a resource | The framework doesn't provision Security Groups at all (no VPC resources). Rule is inapplicable. |
| **CKV_AWS_117** — Lambdas inside a VPC | None of the framework's Lambdas need VPC connectivity — they only call AWS APIs (Cost Explorer, Athena, SNS, DDB, S3, etc.) which work over the public AWS service endpoints. VPC isolation would add cold-start latency + ENI quotas with no security gain. Putting Lambdas in a VPC is on the roadmap for orgs that require strict network isolation. |

### Other Checkov rules: addressed, not suppressed

The Checkov findings genuinely fixed in code (not suppressed):

| Rule | Where addressed |
|---|---|
| **CKV_AWS_50** — X-Ray tracing on Lambda | `tracing_config { mode = "Active" }` block on every `aws_lambda_function`, gated by per-module `xray_tracing_enabled` (default `true`). |
| **CKV_AWS_115** — Lambda reserved concurrency | Per-module `reserved_concurrent_executions` opt-in variable (default `null` = no reservation). |
| **CKV_AWS_195** — Glue security configuration | `aws_glue_security_configuration.cur` attached to the CUR crawler. SSE-KMS for S3 + CloudWatch + CSE-KMS for job bookmarks. |
| **CKV_AWS_300** — S3 abort incomplete multipart uploads | `abort_incomplete_multipart_upload { days_after_initiation = 7 }` on the `athena_results` + `config` bucket lifecycles. |
| **CKV_AWS_338** — CloudWatch log retention ≥ 1 year | `log_retention_days` variable in every module has a `>= 365` validation block. `terraform plan` rejects sub-365 values. |
| **CKV_AWS_21** — S3 versioning (on athena_results + config) | New `aws_s3_bucket_versioning.athena_results` + `aws_s3_bucket_versioning.config`. |
| **CKV2_AWS_61** — S3 lifecycle (on config) | New `aws_s3_bucket_lifecycle_configuration.config` — 90-day noncurrent-version cleanup + 7-day multipart abort. |
