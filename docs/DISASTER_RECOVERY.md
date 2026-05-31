# Solidus FinOps — Disaster Recovery

**Audience:** SRE / oncall / risk management. **As-of:** 2026-05-31.

This document defines per-module RPO (Recovery Point Objective) and RTO
(Recovery Time Objective), enumerates failure modes that constitute a
disaster, and provides the recovery playbook for each.

Pairs with [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md) for routine
day-2 incidents (DLQ filling, alarm spam) and [THREAT_MODEL.md](THREAT_MODEL.md)
for security-incident response.

---

## 1. Scope of "disaster"

A "disaster" in the framework's context is one of:

| Class | Definition | Example |
|---|---|---|
| **D1 — Account-level loss** | The AWS account itself is lost, compromised, or deleted | Compromised root creds; org-level mistake |
| **D2 — Region-level outage** | A primary AWS region is unavailable for > 4h | AWS service event |
| **D3 — Data corruption** | A framework data store is corrupted, deleted, or has untrusted writes | Accidental DDB scan-delete; bucket policy error; insider mistake |
| **D4 — KMS key loss** | The framework CMK is scheduled for deletion or made unusable | Key admin error; AWS bug |
| **D5 — Module-level failure** | A single module's runtime path is broken | All idle-cleanup Lambdas DLQ'd; scheduler stops dispatching |
| **D6 — Audit-trail tampering** | Someone modifies past audit rows | Insider attempts to erase a destructive action's history |

This document covers **D2–D6**. **D1** (account-level loss) requires
org-level continuity planning beyond the framework's scope; AWS
recovery is via legal-entity ownership re-claim.

---

## 2. Per-module RPO / RTO

Recovery Point Objective = maximum acceptable data loss measured in
time. Recovery Time Objective = maximum acceptable downtime.

| Module | Data store | RPO | RTO | Recovery mechanism |
|---|---|---|---|---|
| **alerting** | DDB `alerting-events` (AUDIT + DEDUP) | **0** (PITR) | **30 min** | DDB PITR restore-in-place |
| **cost-data-exports** | S3 `cost-data` bucket (CUR + FOCUS) | **24h** (AWS regenerates on request) | **48h** | AWS re-delivery; recreate bucket from TF if needed |
| **cost-data-exports** | S3 `athena-results` bucket | **N/A** (ephemeral, 30-day TTL) | **0** | Re-run queries |
| **cost-data-exports** | Glue catalog | **24h** (crawler rediscovers on next run) | **24h** | `aws glue start-crawler` |
| **tag-governance** | S3 Config delivery bucket | **0** (versioning ON) | **30 min** | S3 object version restore; Config rules re-evaluate on next CI |
| **tag-governance** | Config rules | **N/A** (no state, defined in TF) | **15 min** | `terraform apply` |
| **budgets** | DDB `budgets-state` (STATE + SNAPSHOT + ACTION) | **0** (PITR) | **30 min** | DDB PITR |
| **budgets** | AWS Budgets resource state | **N/A** (defined in TF) | **15 min** | `terraform apply` |
| **idle-resource-cleanup** | DDB `idle-findings` (STATE + ACTION) | **0** (PITR) | **30 min** | DDB PITR |
| **instance-scheduler** | DDB `scheduler-state` (STATE + ACTION + GSI) | **0** (PITR) | **30 min** | DDB PITR. **Special**: even total loss is non-destructive — see §3.2 |
| **finops-metrics** | DDB `kpi-snapshots` | **0** (PITR) | **30 min** | DDB PITR; trend metrics rebuild from existing CUR via re-aggregation |
| **shared** | KMS CMK | **0** (`prevent_destroy = true` + 30d deletion window) | **24h** (key-recreation requires bucket policy + DDB encrypt-rotate) | See §4 — KMS key recovery is the most painful path |

---

## 3. Recovery playbook per disaster class

### 3.1 D2 — Region-level outage

The framework's primary region is unreachable for an extended period.

**Pre-condition (avoidable):** None of the framework's modules deploy
cross-region replication by default. The cost-data bucket is single-
region. The DDB tables are single-region.

**Immediate steps:**

1. **Confirm the outage.** Check AWS Health Dashboard. If it's truly
   regional, AWS-side recovery typically completes within hours.
2. **Don't fail over.** Failing over for a 4-hour FinOps-stack outage
   creates state-bifurcation problems (two DDB audit tables, two CUR
   feeds, two sets of named queries) that are harder to reconcile than
   the outage itself.
3. **Monitor through the events bus.** The SNS topic publishes through
   AWS infrastructure — alarms will fire on the *other side* of the
   outage when the region recovers.
4. **Document the gap.** Lambda invocations that should have fired
   during the outage *won't* — there's no replay mechanism by design.
   Next-tick reconciliation re-evaluates everything fresh.

**Post-recovery validation:**

```bash
# 1. CUR delivery resumed?
aws s3 ls s3://<name_prefix>-cost-data-<account_id>/cur2/ --recursive | tail

# 2. Glue crawler recovered?
aws glue get-crawler --name <name_prefix>-cur-crawler

# 3. DLQs accumulated traffic during outage?
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --start-time <outage_start> --end-time <outage_end> \
  --period 300 --statistics Maximum --dimensions Name=QueueName,Value=<name_prefix>-dispatcher-dlq

# 4. Replay DLQ if needed (per the OPERATIONAL_RUNBOOK §3)
```

**If the regional outage extends to days**, see §3.5 (data exfiltration
to the secondary region).

### 3.2 D3 — DDB table corruption

**Example:** an operator runs `aws dynamodb scan` and pipes through
`delete-item`, accidentally wiping all STATE rows in the `idle-findings`
table.

**Special property — non-destructive by design:** The framework's
runtime never *depends* on a STATE row existing. STATE rows are
authoritative for "what we've seen lately + what's aged"; if they're
gone, the next scan re-creates them within minutes. ACTION rows
(append-only audit) are the irreplaceable data.

**Steps:**

1. **Stop the bleeding.** Identify the actor:
   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteItem \
     --start-time <approx> \
     | jq '.Events[] | {time:.EventTime, user:.Username, name:.EventName}'
   ```
2. **Restore from PITR.** Pick a point ~5 minutes before the deletion:
   ```bash
   aws dynamodb restore-table-to-point-in-time \
     --source-table-name <name_prefix>-idle-findings \
     --target-table-name <name_prefix>-idle-findings-restored \
     --restore-date-time <iso8601_5min_before>
   ```
3. **Promote the restored table.** Two options:
   - **Fast path** — keep both tables, point the Lambda env var
     `FINDINGS_TABLE_NAME` at the restored one via Terraform.
   - **Clean path** — `aws dynamodb wait table-exists` on restored
     table, then `delete-table` on the corrupted original, then rename
     restored to original. Requires recreate-in-Terraform; about 30
     minutes of careful sequencing.
4. **Audit the recovery.** The restored table includes every ACTION
   row up to the PITR timestamp. ACTION rows after the timestamp
   may be present in CloudTrail data events but require export to
   reconstruct.

**Same procedure** applies to every other DDB table: `alerting-events`,
`budgets-state`, `scheduler-state`, `kpi-snapshots`. Each has PITR ON
and a documented PK/SK shape (see per-module `dynamodb.tf`).

### 3.3 D3 — S3 bucket data corruption / accidental object deletion

**Example:** an operator scripts `aws s3 rm s3://<bucket>/cur2/ --recursive`.

**Special property:** Versioning is ON for `cost-data`, `athena-results`,
and Config buckets. Deleted objects become noncurrent versions, not gone.

**Steps:**

1. **Identify the deletion timestamp** via CloudTrail data events (if
   enabled at the org level) or via S3 inventory.
2. **Restore noncurrent versions** with a parallel `aws s3api
   list-object-versions` + `copy-object` loop, restoring versions older
   than the deletion timestamp:
   ```bash
   aws s3api list-object-versions --bucket <bucket> --prefix cur2/ \
     | jq -r '.Versions[] | select(.IsLatest != true) | "\(.Key) \(.VersionId)"' \
     | while read key vid; do
         aws s3api copy-object \
           --bucket <bucket> --key "$key" \
           --copy-source "<bucket>/${key}?versionId=${vid}"
       done
   ```
3. **Re-run the Glue crawler** to refresh partition metadata:
   ```bash
   aws glue start-crawler --name <name_prefix>-cur-crawler
   ```

**If versioning was disabled** (it shouldn't be — the Terraform resource
has versioning explicitly ON), CUR data can be re-requested from AWS
Billing for any month back to the date the export started; AWS will
re-deliver within ~24h.

### 3.4 D4 — KMS CMK loss

**The most painful path.** The framework's CMK decrypts everything:
S3 buckets, SNS topic, every DDB table, Secrets Manager secrets, every
Lambda env var, every CloudWatch log group.

**Pre-conditions baked into the design:**

- KMS key has `enable_key_rotation = true`.
- KMS key has `deletion_window_in_days = 30` (configurable 7–30 via
  variable).
- KMS key has `lifecycle { prevent_destroy = true }`.
- KMS key has `enable_key_rotation = true` (auto-rotation cascades to
  all encryptions without re-encryption work).

**If the key is in `PendingDeletion` state:**

1. **Cancel the deletion immediately** — you have 7–30 days.
   ```bash
   aws kms cancel-key-deletion --key-id <key_arn>
   ```
2. **Re-enable the key** if it was also disabled:
   ```bash
   aws kms enable-key --key-id <key_arn>
   ```
3. **Audit how it happened.** CloudTrail event `ScheduleKeyDeletion`.
   `aws cloudtrail lookup-events --lookup-attributes
   AttributeKey=EventName,AttributeValue=ScheduleKeyDeletion`

**If the key is permanently deleted** (past the 30-day window):

This is data loss. The encrypted artifacts (CUR data, DDB rows, log
groups) become unreadable. There is no AWS-side recovery.

**Mitigations available before this happens** (do them now if you
haven't):

- Enable AWS Backup with cross-account/cross-region copy for the DDB
  tables. AWS Backup uses a *different* CMK (the AWS Backup vault key)
  — restored items end up encrypted with that key, recoverable.
- Configure cross-region replication on the cost-data bucket to a
  secondary-region bucket encrypted with a *different* CMK. (The
  framework doesn't do this by default — cost vs. benefit calculation
  in [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md).)
- Maintain a documented `aws kms export-key-material` for org-managed
  external KMS (HSM-backed); this requires planning at framework-
  deployment time, not after.

### 3.5 D5 — Module runtime failure

**Example:** every instance-scheduler tick lands in the DLQ. Resources
that should have been stopped at 18:00 stay running.

**Steps:**

1. **Diagnose via the DLQ.** Receive a representative message:
   ```bash
   aws sqs receive-message --queue-url <dlq_url> --max-number-of-messages 1
   ```
   The body contains the EventBridge invocation payload + the Lambda's
   error.
2. **Read the CloudWatch log group** for the offending Lambda. X-Ray
   Active tracing (on by default) shows where the call failed:
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/lambda/<name_prefix>-scheduler \
     --start-time <epoch_ms_24h_ago>
   ```
3. **Apply a hotfix** via `terraform apply` (most common: IAM
   permission gap; Python dependency issue; env-var mistake).
4. **Replay the DLQ** once the Lambda is healthy:
   ```bash
   aws sqs receive-message --queue-url <dlq_url> --max-number-of-messages 10 \
     | jq -r '.Messages[] | .Body' \
     | while read body; do
         aws lambda invoke --function-name <name_prefix>-scheduler \
           --payload "$body" /tmp/out.json
       done
   # Then purge:
   aws sqs purge-queue --queue-url <dlq_url>
   ```

**Per-module non-destructive recovery:**

- **scheduler** — even if every tick failed, the next successful tick
  re-evaluates desired state from scratch and reconciles. No tickless
  catch-up needed.
- **idle-cleanup** — same; idle resources re-appear in the next scan.
  Two-phase EBS deletion makes catch-up safe.
- **finops-metrics** — re-runs are idempotent; same-day re-run
  overwrites the day's DDB SNAPSHOT row.
- **budgets performance** — daily; one missed day creates a missing
  SNAPSHOT row but doesn't affect alarms.
- **tag-governance untagged-cost** — weekly; one missed week loses
  one data point.

### 3.6 D6 — Audit-trail tampering

**Example:** an insider with full IAM admin reads STATE rows from
`idle-findings`, then calls `UpdateItem` to flip `Status = excepted`
on a row that was previously `Status = deleted`, to hide a destructive
action.

**Special property — append-only design:** ACTION rows have unique
SKs derived from `iso_ts + random uuid`. Lambdas never `UpdateItem` on
an ACTION row.

**Detection:**

```bash
# CloudTrail event: UpdateItem against a -ACTION SK row
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateItem \
  --start-time <range> \
  | jq -r '.Events[] | .CloudTrailEvent | fromjson | select(.requestParameters.key.SK.S | startswith("ACTION#"))'
```

**Steps:**

1. **Restore the table to a point before the tampering.** PITR.
2. **Audit the actor** via CloudTrail user identity.
3. **Apply guard policy.** Add an IAM `Deny` SCP on
   `dynamodb:UpdateItem` + `dynamodb:DeleteItem` against the audit
   tables for every IAM principal except the framework's Lambda roles:
   ```json
   {
     "Effect": "Deny",
     "Action": ["dynamodb:UpdateItem", "dynamodb:DeleteItem"],
     "Resource": ["<table_arn>", "<table_arn>/*"],
     "Condition": {"ArnNotLike": {"aws:PrincipalArn": "arn:aws:iam::<acct>:role/<name_prefix>-*-role"}}
   }
   ```
   This is *not* shipped in the framework because it depends on
   org-level IAM Identity Center configuration.

---

## 4. KMS key recovery — detailed playbook

KMS deserves its own section because recovery is uniquely painful.

### Detection — alarms you should have

The framework does NOT auto-provision a CMK-deletion alarm because the
key is in a different lifecycle from the rest. Add this at the
organisation level:

```hcl
resource "aws_cloudwatch_event_rule" "kms_deletion_scheduled" {
  name        = "kms-deletion-scheduled"
  description = "Detect when a CMK is scheduled for deletion"

  event_pattern = jsonencode({
    source        = ["aws.kms"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName   = ["ScheduleKeyDeletion"]
    }
  })
}
```

Target this rule at a PagerDuty / Opsgenie integration. **Always page
on this event** — it has a recovery window measured in days, and the
default 30-day window can easily lapse over a holiday.

### Recovery once deletion is scheduled

```bash
# 1. Identify the key
aws kms list-aliases | jq -r '.Aliases[] | select(.AliasName | contains("finops"))'

# 2. Check pending-deletion state
aws kms describe-key --key-id <alias_or_arn> \
  | jq '.KeyMetadata | {state:.KeyState, deletionDate:.DeletionDate}'

# 3. Cancel
aws kms cancel-key-deletion --key-id <alias_or_arn>

# 4. Re-enable
aws kms enable-key --key-id <alias_or_arn>

# 5. Validate downstream
# Try to decrypt with the key — should succeed:
aws kms encrypt --key-id <alias_or_arn> --plaintext "test"
```

### Pre-event hardening checklist

- [ ] `lifecycle { prevent_destroy = true }` is on the CMK resource (already shipped)
- [ ] `enable_key_rotation = true` (already shipped)
- [ ] `deletion_window_in_days = 30` (shipped; configurable 7–30)
- [ ] CloudWatch event rule on `ScheduleKeyDeletion` (caller-added)
- [ ] CloudWatch event rule on `DisableKey` (caller-added)
- [ ] On-call paging configured for both events
- [ ] AWS Backup vault configured with its own key on the audit DDB tables

---

## 5. Mass-deletion runbook (`scripts/emergency-start-all.sh` analogue)

If a misconfiguration causes the scheduler to stop critical resources, or
idle-cleanup to schedule mass deletion, the framework ships an
emergency-recovery script:

```bash
# Located at modules/instance-scheduler/scripts/emergency-start-all.sh
# Re-starts every resource the scheduler has stopped, in dependency order.

# Same idea for idle-cleanup (TODO — not yet shipped):
# - Scan DDB for STATE rows where Status = approved + Phase = 1
# - Snapshot ID is in the STATE row
# - Restore: aws ec2 create-volume --snapshot-id ... --availability-zone ...
```

If you find yourself reading this section during an active incident:
the **fastest** recovery is usually to set `dry_run = true` for the
offending module + `terraform apply` + manually restore the affected
resources from snapshots / CloudTrail. The scripts are for known-good
recovery; debugging mid-incident is for the runbook.

---

## 6. Tabletop exercise schedule

For production deployments, validate these procedures quarterly:

| Quarter | Drill |
|---|---|
| Q1 | DDB PITR restore on `scheduler-state` |
| Q2 | KMS `cancel-key-deletion` (in a test account) |
| Q3 | DLQ replay on the dispatcher Lambda |
| Q4 | S3 versioned-object restore on the Config bucket |

Each drill should produce a written record in your incident-management
system with: actor, duration, deviation from documented procedure,
required-improvement items.

---

## 7. References

- [OPERATIONAL_RUNBOOK.md](OPERATIONAL_RUNBOOK.md) — day-2 incidents (non-disaster)
- [THREAT_MODEL.md](THREAT_MODEL.md) — security incidents
- [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md) — what the regulator requires
- AWS DynamoDB PITR: aws.amazon.com/dynamodb/pitr
- AWS KMS deletion: docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html
- AWS Backup: aws.amazon.com/backup
