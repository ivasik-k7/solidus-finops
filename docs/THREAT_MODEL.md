# Solidus FinOps — Threat Model

**Audience:** Security review board, application-security lead, internal
audit, IRM team. **As-of:** 2026-05-31. **Methodology:** STRIDE
(Spoofing / Tampering / Repudiation / Information disclosure / Denial of
service / Elevation of privilege). Mitigations cite the specific
Terraform resource or runtime control that enforces them.

For the regulatory mapping (SOX/PCI/GDPR/DORA), see
[COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md). For incident response
procedures, see [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md).

---

## 1. Assets

What the framework manages that has value to an attacker or a regulator:

| Asset | Sensitivity | Why it matters |
|---|---|---|
| **CUR / FOCUS data in S3** | Confidential / financial | Reveals account-wide spend by service, region, account, resource. Used in chargeback; regulator-discoverable. |
| **AWS Config history** | Confidential / audit-grade | Per-resource configuration history; compliance evidence. |
| **DynamoDB audit tables** | Audit-grade | Append-only `ACTION#<iso-ts>` rows record every destructive Lambda action. 7-year retention for SOX/PCI. |
| **Slack / Teams / PagerDuty / Opsgenie webhooks + API keys** | Secret | Inbound paths into the org's incident-response systems. Leak → spoofable on-call pages. |
| **KMS CMK** | Critical | Decrypts every other encrypted artifact in the framework. |
| **Cross-account reader role trust policies** | Critical | Whoever can assume them sees CUR data. |
| **Budget Actions execution role** | Critical | Can attach `Deny` IAM policies to users/groups/roles on budget breach. |
| **EventBridge rule patterns + targets** | Operational | Modification could silence security or governance alerts. |
| **Lambda code** | Operational | Modification could exfiltrate or alter audit data. |
| **Glue catalog metadata** | Confidential | Reveals schema + partition layout of CUR data. |
| **CloudWatch metric data** | Internal | Reveals KPI trends; useful for competitor intelligence. |

---

## 2. Trust boundaries

```
┌────────────────────────────────────────────────────────────────────┐
│                       AWS Account                                  │
│                                                                    │
│  ┌──────────────────┐         ┌──────────────────────────────────┐ │
│  │ AWS service      │ ──CUR── │  S3 cost-data bucket             │ │
│  │ principals       │ ──FOC── │  (SSE-KMS, TLS-only, IAM-scoped) │ │
│  │ billingreports   │         └─┬────────────────────────────────┘ │
│  │ bcm-data-exports │           │ (KMS-decrypt)                    │
│  │ config           │ ──CIs──▶ ┌▼─────────────────┐ ┌─────────────┐│
│  │ glue.crawlers    │ ──S3R──▶ │ Glue crawler     │ │ Lambda fleet││
│  └──────────────────┘          │ (SSE-KMS bookmark)│─│ (KMS env,   ││
│                                └──────────────────┘ │  X-Ray on,  ││
│                                                     │  in-VPC opt)││
│                                                     └──┬──────────┘│
│                                                        │           │
│       ┌────────────────────┐    ┌─────────────────┐   │           │
│       │ Secrets Manager    │◀───┤ DLQs (SSE-SQS)  │◀──┤           │
│       │ webhooks/keys      │    └─────────────────┘   │           │
│       │ (CMK-encrypted)    │                          │           │
│       └────────────────────┘                          │           │
│                                                       │           │
│                                                       ▼           │
│                                              ┌────────────────────┐│
│                                              │  SNS events topic  │ │
│                                              │  (CMK, signed)     │ │
│                                              └──┬─────────────────┘ │
└─────────────────────────────────────────────────┼───────────────────┘
                                                  │
                                                  ▼
            External boundaries (TLS, secret-bound):
            Slack / Teams / PagerDuty / Opsgenie / generic webhooks / email
```

**Trust-boundary crossings the framework introduces:**

1. **AWS billing services → S3 bucket.** Service-principal-restricted,
   `aws:SourceAccount` condition required.
2. **S3 cost-data bucket → Glue crawler.** Crawler role least-privileged
   to the `cur2/*` prefix only.
3. **Glue catalog → Lambda fleet.** Per-Lambda IAM roles, each scoped
   to that Lambda's data needs.
4. **Lambda fleet → SNS events topic.** Per-Lambda role grants
   `sns:Publish` only.
5. **SNS events topic → dispatcher Lambda.** Subscription protected by
   `aws:SourceAccount`.
6. **Dispatcher Lambda → external chat / paging APIs.** Outbound HTTPS
   only; credentials retrieved from Secrets Manager at runtime, never
   stored in env vars or logs.
7. **Foreign account (Cloudability etc.) → cost-data S3.** Cross-account
   reader role; optional external-ID condition.

---

## 3. STRIDE analysis

### S — Spoofing of Identity

| Threat | Impact | Mitigation |
|---|---|---|
| Attacker spoofs a CUR / FOCUS publisher and writes garbage data into the cost-data bucket | Corrupts allocation, masks anomalies | Bucket policy restricts `s3:PutObject` to `billingreports.amazonaws.com` and `bcm-data-exports.amazonaws.com` service principals **with `aws:SourceAccount` = our account ID** ([s3.tf](../modules/cost-data-exports/s3.tf) + [data.tf](../modules/cost-data-exports/data.tf)) |
| Foreign account replays an `AssumeRole` call for a cross-account reader without authorisation | Reads CUR data | Optional `sts:ExternalId` condition on each cross-account reader trust policy ([iam.tf](../modules/cost-data-exports/iam.tf)) |
| Slack / Teams sends a forged event to our SNS topic | Pollutes audit log | SNS topic policy restricts publish principals to `aws:SourceAccount` = our account ([data.tf](../modules/alerting/data.tf)). Inbound webhooks are not modelled (chat → AWS direction); this is a one-way bus. |
| Attacker spoofs Lambda invocations (e.g. EventBridge rule manipulation) | Triggers Lambdas with crafted input | Lambda permission resources scope `source_arn` to the EventBridge rule ARN ([eventbridge.tf](../modules/instance-scheduler/eventbridge.tf) per-module) |
| Attacker spoofs `lambda.amazonaws.com` in role trust policy | Should be impossible; AWS validates principal | Every role's `assume_role_policy` restricts `Principal.Service` to the specific AWS service that needs it (no `*`) |

### T — Tampering with Data

| Threat | Impact | Mitigation |
|---|---|---|
| Modification of CUR data in the S3 bucket | Audit trail corruption | Bucket policy denies all writes to non-service principals; bucket versioning ON; bucket has `prevent_destroy = true` ([s3.tf](../modules/cost-data-exports/s3.tf)) |
| Modification of Config history | Compliance evidence corruption | Config delivery bucket has versioning + 90-day noncurrent-version lifecycle. Current versions retained indefinitely. `prevent_destroy = true` ([s3.tf](../modules/tag-governance/s3.tf)) |
| Modification of DDB audit rows (`ACTION#<iso-ts>`) | Erasing destructive-action history | DDB encrypted with framework CMK; PITR ON; `prevent_destroy = true` on every audit table. Lambda IAM roles grant `PutItem` only — no `DeleteItem`. |
| Modification of audit table SK once written | Same | Application-layer enforcement: Lambdas always `PutItem` with a unique SK derived from `iso_ts + random uuid suffix`. No `UpdateItem` path on ACTION rows. |
| Modification of named queries / Athena workgroup config | Skewed analytics | Workgroup config is `enforce_workgroup_configuration = true` ([athena.tf](../modules/cost-data-exports/athena.tf)) |
| In-transit interception (CUR → S3 / Lambda → SNS / Lambda → AWS APIs) | Data alteration | TLS-only via bucket policy `DenyInsecureTransport`; AWS internal traffic is TLS 1.2+ by default |
| Lambda code modification | Behavior change | Lambda IAM trust policy + code-signing rationale documented in `# checkov:skip=CKV_AWS_272` notes. Operators are advised to pin module ref/commit for supply-chain protection. |

### R — Repudiation

| Threat | Impact | Mitigation |
|---|---|---|
| A team member claims they didn't snooze an idle-resource finding | Allocation dispute | DDB STATE rows record `ActorId = lambda:<function-name>` per write; ACTION rows are append-only with full `iso_ts` + `Reason` |
| An auto-cleanup deleted a resource that should have been preserved | Finger-pointing | Every cleanup writes an ACTION row with `EstimatedSavingsUsd`, the operator-visible reason, and the dry-run flag at the time of action. 7-year retention. |
| Budget Action fired and someone says "we didn't authorize it" | Production-impact dispute | Budget Actions require `approval_model = MANUAL` by default; the budget definition (including the `actions` block) lives in HCL with full git history |
| Someone disables an alarm to hide a fire | Detection bypass | CloudWatch Events fire on `aws_cloudwatch_metric_alarm` state changes; CloudTrail logs `DeleteAlarm` API calls (account-managed CloudTrail required) |
| Tag-drift change goes unaudited | Allocation tampering | EventBridge `aws.tag` rule forwards every allocation-tag mutation to the events bus ([eventbridge.tf](../modules/tag-governance/eventbridge.tf)) |

### I — Information Disclosure

| Threat | Impact | Mitigation |
|---|---|---|
| Reading CUR data without authorisation | Reveals spend by region/service/account/resource | Bucket policy + bucket public-access-block (all 4 blocks ON); SSE-KMS with CMK; bucket key enabled (cost-saver, not security) |
| Reading Athena query results | Reveals what analysts are querying | Athena workgroup writes to a separate `athena-results` bucket with the same KMS protection + 30-day TTL |
| Reading webhook secrets | Spoof chat / on-call pages | Secrets Manager with CMK; Lambda role permits only `secretsmanager:GetSecretValue` on the specific secret ARNs ([iam.tf](../modules/alerting/iam.tf)) |
| Reading DDB audit data without authorisation | Reveals destructive-action history | DDB CMK encryption; Lambda IAM role limits read to GetItem/Query on the table only |
| Reading Lambda env vars (KMS-decrypted at cold start) | Reveals SSM paths / DDB table names / SNS ARNs | Env vars are KMS-encrypted with the framework CMK; only the Lambda role can decrypt |
| Foreign account reads via cross-account reader role | Designed access path | External-ID condition (caller-supplied) protects against confused-deputy; trust policy lists the specific account; reader has `s3:GetObject` only — no `s3:PutObject` |
| CloudWatch log group contents | Reveals operational data + occasional resource IDs | All log groups CMK-encrypted; retention >= 365d enforced via variable validation (`checkov:CKV_AWS_338`) |
| Misconfigured S3 bucket policy | Public-access exposure | `aws_s3_bucket_public_access_block` resource explicitly blocks all 4 access vectors; bucket policy explicitly denies non-TLS |
| KMS key compromise | Decrypts everything | KMS key rotation enabled; deletion window 30d; bucket policy scoped to the key — leaking the key alone doesn't grant data access without account creds |

### D — Denial of Service

| Threat | Impact | Mitigation |
|---|---|---|
| Lambda flooding via spoofed EventBridge | Burn through Lambda concurrency | Per-module `reserved_concurrent_executions` opt-in (default null → AWS account default). Set to `-1` as an incident kill switch. |
| Lambda flooding via SNS-fanout amplification | DLQ saturation | Dispatcher Lambda has its own DLQ (SSE-SQS, 14-day retention); CloudWatch alarm on DLQ depth fires before queue fills |
| Cost-data S3 bucket fills disk | Storage cost explosion | Lifecycle config: 90d transition to GLACIER_IR (Athena-queryable, 68% cheaper); noncurrent versions to DEEP_ARCHIVE → expire at 90d |
| AWS Config rate limits / cost explosion | Spend runaway | Config delivery rate is AWS-controlled. Cost model documents the variable: see [COST_ESTIMATE.md §3.5](COST_ESTIMATE.md) |
| Cost Explorer API throttling | Aggregator failures | `botocore.Config(retries={"max_attempts": 10, "mode": "adaptive"})` on every framework Lambda; per-KPI try/except so one throttled call doesn't fail the rest |
| Athena query queue exhaustion | KPI aggregator stalls | Single workgroup, no concurrency cap on the workgroup; query timeout 180s per query; per-query try/except in `kpi_aggregator.py` |
| EBS phase-2 delete fires while a snapshot is in-flight | Data loss | Two-phase delete: phase 1 snapshots + tags `FinOpsPendingDeletion=<snap>`; phase 2 finalizes only when snapshot status = "completed" AND grace period elapsed; rollback after `ebs_pending_grace_max_hours` |
| Instance scheduler stops a production instance by mass mis-tag | Production outage | Action-count blast-radius cap (`max_actions_per_tick = 200` default); scheduler defers excess to next tick; `FinOpsException = true` tag exempts; spot management opt-in only |
| Budget Action fires and removes IAM access from prod | Production outage | `approval_model = MANUAL` default — human must approve each fire; `actions` block requires explicit configuration; ACTION row records the operator who approved |
| DLQ fills and silently saturates | Loss of failed-invocation context | Per-Lambda DLQ-depth CloudWatch alarm publishes to events bus; 14-day retention buys triage time |

### E — Elevation of Privilege

| Threat | Impact | Mitigation |
|---|---|---|
| Lambda role assumes Budget Actions role | Lateral movement to a destructive IAM modifier | Budget Actions trust policy restricts assume to `budgets.amazonaws.com` ONLY, with `aws:SourceAccount` condition. Lambda principal isn't trusted. |
| Budget Action policy attaches a too-broad IAM policy to a user | Effective privilege escalation | Operators configure `iam_policy_arn` explicitly per-action. The framework cannot pre-validate the policy contents. Mitigation: `approval_model = MANUAL` requires human review per fire. |
| Cross-account reader role gains write access | Foreign account modifies CUR | Cross-account reader policy is `s3:GetObject` / `glue:Get*` / `kms:Decrypt` only — no `Put*`/`Delete*`. Validation regex on `account_id` field. |
| Lambda code injection via malicious schedule | Run arbitrary code in Lambda role | Lambdas don't `eval` schedule definitions — schedules are parsed structurally (`days`, `start`, `stop`, `timezone`). Custom KPIs accept SQL, executed by Athena (sandboxed). |
| SSM Parameter Store hijack | Lambda reads malicious value | The framework no longer stores rate tables in SSM (removed in v0.1 — rate tables are wrong on day 1). SSM is read-only for KPI mirrors written by the framework's own Lambdas. |
| EBS volume snapshot then attach to attacker's instance | Data exfiltration | Snapshot lifecycle is in the same account; cross-account snapshot sharing is not enabled by the framework. Operators must explicitly share snapshots if needed. |
| Cross-account reader writes to Athena results bucket | Reader exfiltrates queries / pollutes results | Athena `enable_athena = true` on a reader grants `s3:PutObject` ONLY on the athena-results bucket (segregated from cost-data). Query results auto-expire at 30 days. |

---

## 4. Defence-in-depth summary

The framework layers controls so that compromise of any one boundary
doesn't grant material capability:

| Layer | Control |
|---|---|
| **Authentication** | IAM + KMS + Secrets Manager. No long-lived keys in any artifact. |
| **Authorisation** | Per-Lambda least-privilege role; documented `# checkov:skip=` rationales where AWS forces `*`. |
| **Network** | TLS-only bucket policy; AWS internal traffic on TLS 1.2+; outbound webhook calls over HTTPS only. |
| **Encryption** | Customer-managed CMK on S3 (CUR + Config + Athena results), SNS, DynamoDB, Secrets Manager, CloudWatch Logs, Glue (bookmarks + crawler logs). Rotation enabled, 30-day deletion window. |
| **Audit** | DDB STATE + ACTION rows (7-year retention); CloudTrail (account-managed); CloudWatch Logs (CMK-encrypted, configurable retention); SNS event-bus publish to external SIEM optional. |
| **Detection** | CloudWatch alarms on every Lambda's `Errors` metric and DLQ depth; tag-drift event rule; Config rules with NON_COMPLIANT → events bus. |
| **Recovery** | DDB PITR; S3 bucket versioning; `prevent_destroy = true` on data tables + buckets; documented runbook ([OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md)). |
| **Blast radius** | `max_actions_per_tick` on the scheduler; cost-ceiling on idle-cleanup; dry-run default; manual-approval default on Budget Actions; reserved-concurrency kill switch. |

---

## 5. Known accepted risks

Listed in [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md) under "Documented
Checkov suppressions". Each carries inline `# checkov:skip=` with
specific rationale. Summary:

| Risk class | Why accepted |
|---|---|
| `Resource = "*"` in some IAM policies | AWS Service Authorization Reference documents that several actions (`ec2:DeleteVolume`, `athena:StartQueryExecution`, `glue:GetDatabase`, `cloudwatch:PutMetricData`, etc.) do not support resource-level permissions. Scope is enforced via `dry_run` + `EXCEPTION_TAG_KEY` filtering at the Lambda runtime. |
| Lambda code signing not enabled | Requires AWS Signer infrastructure (signing profile + signing config) which is an enterprise opt-in. Supply-chain protection mitigated by pinning the module ref/commit. |
| Cross-region replication on data buckets not enabled | CUR data can be regenerated by AWS on request; CRR would double storage cost without proportional audit value. |
| S3 access logging not enabled | Audit-grade access log is provided by CloudTrail S3 data events at the org level (out of scope for this module). |
| `CKV2_AWS_57` (Secrets Manager auto-rotation) on every chat secret | Slack/Teams/PD/Opsgenie webhook rotation must be initiated on the third-party side; AWS Secrets Manager cannot drive it. Operators rotate manually. |
| Notebook export ranges not auto-anonymized | CUR data is intentionally precise (one row per usage line); anonymisation belongs in the downstream analytics layer if needed. |

---

## 6. Threats explicitly out of scope

Stated honestly so security review doesn't assume false coverage:

- **AWS account compromise (root credentials).** Outside the framework's
  control. Mitigation: AWS Organizations + IAM Identity Center + MFA at
  the org level.
- **Cross-account fan-out attacks.** The framework operates in one
  account. Multi-account governance is a roadmap item.
- **Insider with `iam:*` permissions in the deployment account.** Any
  caller with full IAM admin can disable controls. Mitigation:
  Service Control Policies + audit at the org level.
- **AWS service vulnerabilities.** Trust the platform; we layer
  defence-in-depth on top of it.
- **Supply-chain attack on the Terraform module distribution.** Pin
  `source` to a specific commit or signed release tag. Apache 2.0
  license + git history + NOTICE attribution provide provenance.
- **Lambda runtime CVEs.** AWS auto-patches runtime versions; framework
  pins `python3.12` and the variable validation accepts only currently-
  supported runtimes.

---

## 7. Validation checklist for security review

Before approving production deployment, confirm:

- [ ] Customer-managed CMK exists and has rotation enabled
- [ ] All S3 buckets have public-access-block on (4 settings true)
- [ ] All S3 buckets have versioning + KMS encryption + lifecycle policies
- [ ] All DDB tables have CMK encryption + PITR + `prevent_destroy = true`
- [ ] All Lambda functions have a DLQ + Errors alarm + DLQ-depth alarm
- [ ] All Lambdas have `tracing_config { mode = "Active" }` (X-Ray)
- [ ] All Lambdas use the framework CMK for env-var encryption
- [ ] All log groups have retention ≥ 365 days
- [ ] No Lambda has hardcoded secrets in env vars (`grep -r kms_key_arn modules/` is fine; `grep -r AKIA modules/` MUST be empty)
- [ ] Every IAM `Resource = "*"` is accompanied by a `# checkov:skip=` rationale
- [ ] `idle_cleanup_dry_run = true` for the first 4 weekly cycles
- [ ] `approval_model = MANUAL` on all Budget Actions for production accounts
- [ ] `cross_account_readers` entries include `external_id` for any 3rd-party tool
- [ ] `terraform plan` produces zero `+` for IAM `*` after the module's own resources
- [ ] Account has CloudTrail enabled at the org level (separate concern)
- [ ] Run `tflint --recursive` and `checkov` with `soft_fail: false` in CI

---

## 8. Reporting a vulnerability

See [SECURITY.md](../SECURITY.md). GitHub Security Advisories is the
preferred channel; 48h ack, 7d triage, 30–90d disclosure window.
