# Solidus FinOps — Operational Runbook

**Audience:** SRE / Platform / FinOps oncall. **As-of:** 2026-05-31.

This is the **day-2 operational runbook** for the Solidus FinOps
framework. It covers routine incidents — DLQs filling, Lambda alarms,
budget-related noise, CUR staleness, allocation drift — and the
procedures that fix them. It is *not* the disaster playbook (see
[DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) for D1–D6 class events:
region outage, KMS key loss, DDB corruption, mass deletion) and it is
*not* the security-incident playbook (see [THREAT_MODEL.md](THREAT_MODEL.md)
for STRIDE-mapped detections and response paths). If something on this
page looks like a disaster or a security incident, escalate per §6 and
pivot to the appropriate doc immediately.

The framework deploys 7 modules under a single `<namespace>-<environment>-<stack>`
prefix (default: `examplebank-shared-finops`). 13 Lambdas. 5 DynamoDB
tables. 5 auto-provisioned dashboards. One shared CMK. One shared SNS
topic. Everything is single-region by design; everything is encrypted
with the same CMK; X-Ray Active tracing is on for every Lambda.

---

## 1. Naming + identifying things

Set these once at the top of an oncall shell and the rest of this doc
copy-pastes cleanly.

```bash
set -euo pipefail
export NAME_PREFIX="examplebank-shared-finops"
export AWS_REGION="eu-west-1"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

The **single-glance status** of the framework is in a Terraform output —
prefer it over any of the per-resource lookups below:

```bash
terraform output -json framework_status | jq
```

That dumps `name_prefix`, `primary_region`, `secondary_regions`,
`effective_regions`, `kms_key_arn`, `events_topic_arn`, and a `dashboards`
map keyed by module slug → dashboard name. If `framework_status` is
empty or stale, run `terraform refresh` first.

### 1.1 Where everything lives

| Category | Resource name pattern | Notes |
|---|---|---|
| **Lambda — alerting** | `<NAME_PREFIX>-dispatcher` | Multi-channel event dispatcher. DLQ: `<NAME_PREFIX>-dispatcher-dlq`. |
| **Lambda — cost-data-exports** | `<NAME_PREFIX>-cost-data-health` | CUR freshness + crawler health. DLQ: `<NAME_PREFIX>-cost-data-health-dlq`. |
| **Lambda — tag-governance** | `<NAME_PREFIX>-untagged-cost` | Weekly untagged-cost report. DLQ: `<NAME_PREFIX>-untagged-cost-dlq`. |
| **Lambda — budgets** | `<NAME_PREFIX>-budget-perf` | Daily per-budget variance + burn-rate. DLQ: `<NAME_PREFIX>-budget-perf-dlq`. |
| **Lambda — idle-cleanup (×6)** | `<NAME_PREFIX>-idle-{ebs,eip,snapshot,nat,eni,lb}` | One Lambda per resource type. Per-type DLQ: `<NAME_PREFIX>-idle-<type>-dlq`. |
| **Lambda — scheduler (×2)** | `<NAME_PREFIX>-scheduler`, `<NAME_PREFIX>-scheduler-discovery` | Tick + weekly discovery. DLQs: `…-dlq` each. |
| **Lambda — kpi-aggregator** | `<NAME_PREFIX>-kpi-aggregator` | Athena-driven KPI rollup. DLQ: `<NAME_PREFIX>-kpi-aggregator-dlq`. |
| **DDB — alerting** | `<NAME_PREFIX>-alerting-events` | `AUDIT#…` rows + `DEDUP#…` rows. PITR on. |
| **DDB — budgets** | `<NAME_PREFIX>-budgets-state` | `STATE` / `SNAPSHOT` / `ACTION` rows. PITR on. |
| **DDB — idle-cleanup** | `<NAME_PREFIX>-idle-findings` | `STATE` + `ACTION` rows. PITR on. |
| **DDB — scheduler** | `<NAME_PREFIX>-scheduler-state` | `STATE` + `ACTION` rows + GSI for action lookups. PITR on. |
| **DDB — finops-metrics** | `<NAME_PREFIX>-kpi-snapshots` | Daily SNAPSHOT rows. PITR on. |
| **DLQ index (all)** | `terraform output -json lambda_dlq_arns \| jq` | Single authoritative list of every Lambda DLQ. |
| **Dashboards** | `<NAME_PREFIX>-{cost-data-exports,budgets,idle-cleanup,scheduler,kpis}` | Five auto-provisioned. Cross-linked in `framework_status.dashboards`. |
| **KMS CMK** | Alias `alias/<NAME_PREFIX>-cmk`; ARN in `terraform output kms_key_arn` | Auto-rotation on. 30-day deletion window. `prevent_destroy = true`. |
| **SNS topic** | ARN in `terraform output events_topic_arn` | CMK-encrypted. Subscribed by `dispatcher` Lambda. |
| **S3 — cost data** | `<NAME_PREFIX>-cost-data-<ACCOUNT_ID>` | CUR 2.0 + FOCUS 1.0. Versioning on. SSE-KMS. TLS-only. |
| **S3 — Athena results** | `<NAME_PREFIX>-athena-results-<ACCOUNT_ID>` | 30-day TTL. SSE-KMS. |
| **S3 — Config delivery** | `<NAME_PREFIX>-config-<ACCOUNT_ID>` | Versioning on. SSE-KMS. |
| **Metric namespaces** | `FinOps/Alerting`, `FinOps/Budgets`, `FinOps/CostDataExports`, `FinOps/IdleResources`, `FinOps/InstanceScheduler`, `FinOps/KPIs`, `FinOps/TagGovernance` | One namespace per module. Definitions in [METRICS_GLOSSARY.md](METRICS_GLOSSARY.md). |
| **SSM mirrors** | `/<NAME_PREFIX>/{budgets,tag-governance,finops-metrics}/…` | Read-only mirrors of the KPI metrics. Cheap to poll from external tooling. |
| **CloudWatch log groups** | `/aws/lambda/<lambda-name>` | KMS-encrypted. 90-day retention by default. |

If you cannot find a resource via the above, walk Terraform outputs:

```bash
terraform output -json | jq 'keys'
```

Each module's outputs include `*_lambda_arn(s)`, `*_dashboard_name`, and
`*_metric_namespace` so you can locate everything from state without
re-running `aws ... list-*`.

---

## 2. The 5 most common operational alerts

These are the alarms you will see week-to-week. Each subsection lists
**signal → diagnose → resolve**. Every code block assumes the env vars
from §1 are exported.

### 2.1 `<lambda>-dlq-depth > 0` — DLQ has messages

**Signal.** Any CloudWatch alarm of the form `<NAME_PREFIX>-<lambda>-dlq-depth`
in `ALARM` state. The DLQ alarm threshold is `ApproximateNumberOfMessagesVisible > 0`
for 1 datapoint of 5 minutes (i.e. fires fast).

**Diagnose.**

```bash
DLQ_URL="$(aws sqs get-queue-url --queue-name "${NAME_PREFIX}-scheduler-dlq" --query QueueUrl --output text)"

# 1. How many messages, and how stale?
aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage

# 2. Peek (does NOT delete — visibility timeout returns it):
aws sqs receive-message --queue-url "$DLQ_URL" \
  --max-number-of-messages 1 --visibility-timeout 5 \
  | jq '.Messages[0].Body | fromjson'
```

Cross-reference the message body against the Lambda's logs at the
approximate timestamp:

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/${NAME_PREFIX}-scheduler" \
  --start-time "$(date -d '2 hours ago' +%s)000" \
  --filter-pattern "ERROR"
```

**Resolve.** Decide one of three:

- **Replay** — root cause was transient (throttling, dependency
  flap). After the Lambda recovers, drain the DLQ:

  ```bash
  set -euo pipefail
  LAMBDA="${NAME_PREFIX}-scheduler"
  while true; do
    MSG="$(aws sqs receive-message --queue-url "$DLQ_URL" \
            --max-number-of-messages 1 --wait-time-seconds 2)"
    [ -z "$MSG" ] && break
    BODY="$(echo "$MSG"   | jq -r '.Messages[0].Body')"
    HANDLE="$(echo "$MSG" | jq -r '.Messages[0].ReceiptHandle')"
    aws lambda invoke --function-name "$LAMBDA" \
      --payload "$BODY" --cli-binary-format raw-in-base64-out /tmp/out.json
    aws sqs delete-message --queue-url "$DLQ_URL" --receipt-handle "$HANDLE"
  done
  ```

- **Discard** — root cause was a malformed event you do not want
  replayed. `aws sqs purge-queue --queue-url "$DLQ_URL"`. Document
  why in the incident ticket.

- **Forward** — root cause needs human review (suspect tampering,
  policy event). Copy messages to a quarantine bucket before purging.

**Escalate** to Sev-2 (see §6) if DLQ depth > 10 messages or the
oldest message is > 24h old.

### 2.2 `<lambda>-errors > 0` — Lambda erroring before DLQ catch

**Signal.** `<NAME_PREFIX>-<lambda>-errors` alarm. Source metric:
`AWS/Lambda` `Errors`. Fires on the first non-zero datapoint.

`-errors` alarms typically lead `-dlq-depth` alarms by 1–5 minutes (the
event has to fail enough retries to land in the DLQ). Treat an
`-errors`-only alert as the early-warning version of §2.1.

**Diagnose.**

```bash
# X-Ray service map for the last hour — fastest way to see the failure point
aws xray get-service-graph \
  --start-time "$(date -d '1 hour ago' -u +%FT%TZ)" \
  --end-time   "$(date -u +%FT%TZ)" \
  | jq '.Services[] | {name:.Name, errorStats:.SummaryStatistics.ErrorStatistics}'

# Recent errors with the request ID for cross-ref
aws logs filter-log-events \
  --log-group-name "/aws/lambda/${NAME_PREFIX}-budget-perf" \
  --filter-pattern '?ERROR ?Exception ?Traceback' \
  --start-time "$(date -d '30 minutes ago' +%s)000" \
  | jq -r '.events[] | "\(.timestamp) \(.message)"' | head -40
```

**Common root causes & resolution paths.**

| Pattern in logs | Likely cause | Fix |
|---|---|---|
| `AccessDenied` / `is not authorized to perform` | IAM gap after upstream change | `terraform plan` on the module; re-apply IAM policy |
| `botocore.errorfactory.ResourceNotFoundException` | Resource referenced by Lambda was deleted out-of-band | Recreate via TF; verify drift with `terraform plan` |
| `ThrottlingException` / `Rate exceeded` | API throttling burst | Confirm transient; replay DLQ once steady |
| `ProvisionedThroughputExceededException` | DDB hot key | Confirm; if recurring, raise capacity or check for runaway loop |
| Athena `QueryExecutionTimeout` | Slow / scanning Athena query | Re-run Glue crawler; verify partition pruning |
| `KMS … is disabled` | CMK accidentally disabled | **Stop** — pivot to [DISASTER_RECOVERY.md §3.4](DISASTER_RECOVERY.md) |

If logs show `KMS … is disabled`, `ScheduleKeyDeletion`, or any error
mentioning the framework CMK, **escalate to Sev-1 immediately** and
switch to the KMS recovery section of `DISASTER_RECOVERY.md`.

### 2.3 Budget-related alarms — `budget-adherence-low` + `budget-burn-rate-low`

**Signal.** Either:

- `<NAME_PREFIX>-budget-adherence-low` — fleet-wide adherence score
  (% of budgets within tolerance) dropped below threshold (default 80).
- `<NAME_PREFIX>-budget-burn-rate-low` — per-budget `BurnRateDaysToBreach`
  dropped below the configured floor (default 7 days).

Both are **business** alarms, not platform-failure alarms. Treat them
as Sev-3 unless multiple budgets are involved.

**Diagnose.**

```bash
# Which budgets are off-track?
aws cloudwatch get-metric-statistics \
  --namespace FinOps/Budgets \
  --metric-name BurnRateDaysToBreach \
  --start-time "$(date -d '7 days ago' -u +%FT%TZ)" \
  --end-time   "$(date -u +%FT%TZ)" \
  --period 86400 --statistics Minimum \
  --dimensions "Name=Budget,Value=${NAME_PREFIX}-platform-monthly"

# Pull the budget's DDB state for the storyline
aws dynamodb query \
  --table-name "${NAME_PREFIX}-budgets-state" \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk":{"S":"BUDGET#platform-monthly"}}'
```

**Resolution paths.**

- **Confirm the spend is real** — check Cost Explorer, look for an
  anomaly event, cross-reference with recent deploys.
- **Notify budget owner** — they are listed in `budgets_items[*].owner_email`
  in tfvars. The Slack/email notification should already have gone out
  via dispatcher; if it didn't, see §2.1.
- **Adjust the budget** if the threshold is genuinely wrong; do this
  via Terraform, not the AWS console (drift will surface in the next
  quarterly check, §5).
- **Trigger a budget action** if you have one configured (`Deny` IAM
  policy attach). This is a **business** decision, not an oncall
  decision — escalate to the budget owner.

`VariancePct > 100` for a budget on day 1 of the month usually means a
true-up posted late; wait 24h before treating it as real.

### 2.4 `cur-delivery-stale` — CUR pipeline stopped

**Signal.** `<NAME_PREFIX>-cur-delivery-stale` alarm. Source: the
`FinOps/CostDataExports` `HoursSinceLastCurDelivery` metric — exceeds
36h by default.

**Diagnose.**

```bash
# 1. When did we last see a CUR object?
aws s3api list-objects-v2 \
  --bucket "${NAME_PREFIX}-cost-data-${ACCOUNT_ID}" \
  --prefix "cur2/" \
  --query 'reverse(sort_by(Contents,&LastModified))[0:5].[Key,LastModified]'

# 2. Is the BCM Data Export still configured?
aws bcm-data-exports list-exports --query 'Exports[].{Name:Name,Status:DestinationConfigurations}'

# 3. Is the Glue crawler still scheduled + last-run state?
aws glue get-crawler --name "${NAME_PREFIX}-cur-crawler" \
  --query 'Crawler.{State:State,LastCrawl:LastCrawl}'
```

**Resolution paths.**

| Finding | Action |
|---|---|
| Last object < 36h old but alarm firing | Check the health-check Lambda — likely a §2.2 incident, not a true CUR outage |
| Last object > 48h old, export status unhealthy | AWS-side delivery issue. Open AWS Support case. No customer-side action moves this faster. |
| Export config drift (someone disabled it) | `terraform apply` to re-create. Audit via CloudTrail (`UpdateExport`, `DeleteExport`). |
| Crawler stuck `RUNNING` > 1h | `aws glue stop-crawler --name "${NAME_PREFIX}-cur-crawler"`; restart |
| Crawler last-run failed | Inspect `LastCrawl.ErrorMessage`. Usually IAM or KMS — `terraform apply`. |

If CUR has been stale for > 72h, escalate to Sev-2 (downstream KPIs
will start drifting because Athena queries return empty for the
current period).

### 2.5 Allocation-coverage WoW drift — allocation regression

**Signal.** The KPI dashboard's "Allocation coverage %" sparkline shows
a week-over-week drop. There is a CloudWatch alarm
`<NAME_PREFIX>-allocation-coverage-drop` on the `AllocationCoveragePct`
metric in `FinOps/KPIs`. Threshold drops > 5 percentage points WoW.

This usually means somebody deployed something without tags.

**Diagnose.**

```bash
# 1. Pull the per-tag-key coverage breakdown for this week vs last
aws cloudwatch get-metric-statistics \
  --namespace FinOps/TagGovernance \
  --metric-name CoveragePct \
  --start-time "$(date -d '14 days ago' -u +%FT%TZ)" \
  --end-time   "$(date -u +%FT%TZ)" \
  --period 86400 --statistics Average \
  --dimensions "Name=TagKey,Value=cost-center"

# 2. Run the untagged-cost named query (Athena) — top 50 offenders
aws athena start-query-execution \
  --work-group "${NAME_PREFIX}-finops-wg" \
  --query-string "$(aws athena get-named-query \
    --named-query-id $(terraform output -json finops_metrics_named_query_ids | jq -r '.untagged_cost_top_n') \
    --query NamedQuery.QueryString --output text)"
```

**Resolution paths.**

- **Identify the deploy** — cross-reference the WoW drop date against
  CloudTrail `RunInstances` / `CreateDBInstance` / Terraform-runner
  job logs.
- **Notify the offending team** — the dispatcher should already have
  sent a Slack/email; if not, see §2.1.
- **Backfill tags** with an `aws … create-tags` script if the
  resources are tag-compatible. Coverage re-evaluates on the next
  Config CI cycle (~minutes).
- **Add the team's tag value to the dashboard** if a new business
  unit is onboarding — see §3.8.

A WoW drop of > 10 percentage points without an identifiable cause is
Sev-2 — it usually means the tag-governance Lambda or Config rules
themselves are mis-firing, not that resources are actually untagged.

---

## 3. Common operational procedures

The procedures most likely to come up in an oncall rotation, in
roughly increasing risk order.

### 3.1 Flip idle-cleanup from dry-run to active

**Default after install:** all 6 idle Lambdas run in `dry-run` mode —
they discover, score, and write `STATE` rows, but do *not* delete.

**Pre-conditions before flipping:**

1. The module has been in dry-run for **at least 14 days** in this
   environment.
2. The `<NAME_PREFIX>-idle-findings` DDB table has STATE rows for the
   resource types you plan to enable.
3. You have spot-checked at least 10 random findings and confirmed
   they are genuinely idle (not a Friday-evening artefact).
4. The `FinOpsException = true` snooze tag (§3.2) is documented and
   communicated to resource owners.
5. Two-phase EBS deletion (snapshot → delete-after-N-days) is
   configured if you are enabling EBS.

**Flip:**

```bash
# Per-type. Recommended order: snapshot, eip, eni, lb, nat, ebs.
# Edit terraform.auto.tfvars:
#   idle_cleanup_action_modes = {
#     ebs = "active", eip = "active", snapshot = "active",
#     nat = "dry-run", eni = "active", lb = "active",
#   }
terraform plan -target=module.idle_resource_cleanup
terraform apply -target=module.idle_resource_cleanup
```

Watch the dashboard for 24h after each type goes active.

### 3.2 Snooze an idle-resource finding (FinOpsException tag)

A resource owner objects to a finding ("it looks idle, but it's a
hot-standby"). Snooze, don't argue.

```bash
aws ec2 create-tags \
  --resources vol-0abc123def456 \
  --tags Key=FinOpsException,Value=true \
         Key=FinOpsExceptionReason,Value="hot-standby for failover, owner: payments@" \
         Key=FinOpsExceptionExpires,Value=2026-09-30
```

The idle Lambdas skip any resource with `FinOpsException = true`. The
`Expires` value is read by the weekly governance report — exceptions
without an expiry surface to the FinOps team for cleanup.

To list current exceptions:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=FinOpsException,Values=true \
  --query 'ResourceTagMappingList[].[ResourceARN,Tags[?Key==`FinOpsExceptionExpires`].Value|[0]]' \
  --output table
```

### 3.3 Force a one-off Lambda run

The KPI aggregator runs daily on EventBridge. To force a re-aggregation
(e.g. after fixing a tag backfill from §2.5):

```bash
aws lambda invoke \
  --function-name "${NAME_PREFIX}-kpi-aggregator" \
  --invocation-type RequestResponse \
  --payload '{"source":"manual","reason":"backfill-after-tagging-fix"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/out.json
jq . /tmp/out.json
```

Every Lambda is idempotent for same-day re-runs: a re-run overwrites
the day's `SNAPSHOT` row in DDB and re-publishes the day's metrics.
Re-runs are safe.

### 3.4 Test a webhook before saving

Before storing a new Slack/Teams webhook in Secrets Manager, smoke-test
it directly:

```bash
WEBHOOK_URL="https://hooks.slack.com/services/T.../B.../..."
curl -sS -X POST -H 'Content-Type: application/json' "$WEBHOOK_URL" \
  --data '{"text":"finops-runbook test — '"$(date -u +%FT%TZ)"' — ignore"}'
# Expect: "ok"
```

Once it works, store it via Terraform (`var.alerting_channels[*].webhook_url`
or `secret_arn`). Do **not** paste it into the Secrets Manager console —
that bypasses the audit trail and the CMK association will need
fixing.

### 3.5 Pause a misbehaving module via reserved concurrency (kill switch)

This is the universal kill switch: set Lambda reserved concurrency to
`0` and the Lambda stops invoking, immediately, with no Terraform
roundtrip.

```bash
aws lambda put-function-concurrency \
  --function-name "${NAME_PREFIX}-idle-ebs" \
  --reserved-concurrent-executions 0
```

Events keep queuing (EventBridge → Lambda → throttled → DLQ after
retries) — so plan to clear the DLQ when you re-enable. To re-enable:

```bash
aws lambda delete-function-concurrency \
  --function-name "${NAME_PREFIX}-idle-ebs"
```

Use this for: a Lambda actively causing harm; a Lambda whose blast
radius you do not yet understand; a Lambda whose DLQ is full of
poison-pill messages you do not want auto-retried.

**Do not** use this for: routine pauses (use `terraform apply` with
`enabled = false`); planned maintenance windows (use EventBridge
rule disable).

### 3.6 Rotate a Slack webhook

Slack rotation is **not** an in-place secret update — Slack issues a
new URL and invalidates the old one server-side.

```bash
# 1. In Slack: regenerate webhook in the channel's app settings. Copy the new URL.
# 2. Smoke-test (§3.4).
# 3. Put the new value:
aws secretsmanager put-secret-value \
  --secret-id "${NAME_PREFIX}-slack-webhook" \
  --secret-string "$WEBHOOK_URL"
# 4. Verify the dispatcher picks up the new value within ~60s
#    (Secrets Manager cache TTL inside the Lambda):
aws sns publish --topic-arn "$(terraform output -raw events_topic_arn)" \
  --message '{"severity":"info","title":"webhook-rotation-test","detail":{}}' \
  --message-attributes 'severity={DataType=String,StringValue=info}'
```

If the rotation is in response to a suspected leak, **stop** — pivot
to [THREAT_MODEL.md](THREAT_MODEL.md) (information-disclosure /
spoofing of incident channel). The procedure there includes audit-log
review and confirming no spoofed events were dispatched between leak
and rotation.

### 3.7 Replay a missed scheduler tick (note: usually unnecessary)

The scheduler is **idempotent by design** — the next successful tick
re-evaluates desired state from scratch. If a tick was missed (e.g.
during a brief outage), the next tick reconciles. You should **not**
need to replay.

The exception: the missed tick covered a *narrow* desired-state window
that has already passed by the time the Lambda recovered. Example: the
18:00 stop tick was missed; it's now 18:45; resources that should have
been stopped at 18:00 are still running and burning money.

```bash
# Manually invoke with the EventBridge-shaped payload:
aws lambda invoke \
  --function-name "${NAME_PREFIX}-scheduler" \
  --invocation-type RequestResponse \
  --payload '{"source":"manual-replay","reason":"missed-1800-tick","tick_iso":"2026-05-31T18:00:00Z"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/out.json
```

The scheduler logs an `ACTION` row with `source = "manual-replay"` so
the audit trail distinguishes manual interventions from cron ticks.

### 3.8 Onboard a new tag value to the per-tag-value dashboard

A new business unit / cost-center is rolling out; you want them on the
allocation dashboard.

```bash
# 1. Add the tag value to terraform.auto.tfvars:
#    tag_governance_allocation_values = {
#      cost-center = ["payments","trading","retail","NEW-BU"]
#    }
terraform plan  -target=module.tag_governance -target=module.finops_metrics
terraform apply -target=module.tag_governance -target=module.finops_metrics

# 2. The dashboard re-provisions on apply; the per-tag-value metric
#    starts publishing on the next kpi-aggregator run (daily 02:00 UTC).
# 3. Trigger an early run if needed (§3.3).
```

The resource group + Config rule for the new value provision in the
same apply — no second pass required.

---

## 4. Quarterly health checks

Run these once per quarter (or after any framework upgrade). Each is a
one-liner; expect "all green" output in a healthy environment.

**Every Lambda has run successfully in the last 30 days.**

```bash
for fn in $(aws lambda list-functions \
              --query "Functions[?starts_with(FunctionName,'${NAME_PREFIX}-')].FunctionName" \
              --output text); do
  LAST=$(aws cloudwatch get-metric-statistics \
           --namespace AWS/Lambda --metric-name Invocations \
           --dimensions "Name=FunctionName,Value=${fn}" \
           --start-time "$(date -d '30 days ago' -u +%FT%TZ)" \
           --end-time   "$(date -u +%FT%TZ)" \
           --period 86400 --statistics Sum \
           --query 'Datapoints[?Sum>`0`] | length(@)')
  echo "${fn} active-days-of-30: ${LAST}"
done
```

**Every DLQ is empty.**

```bash
for q in $(terraform output -json lambda_dlq_arns | jq -r 'values[]' | awk -F: '{print $NF}'); do
  URL=$(aws sqs get-queue-url --queue-name "$q" --query QueueUrl --output text)
  N=$(aws sqs get-queue-attributes --queue-url "$URL" \
        --attribute-names ApproximateNumberOfMessages \
        --query Attributes.ApproximateNumberOfMessages --output text)
  printf '%-50s %s\n' "$q" "$N"
done
```

**Every alarm is in `OK` state.**

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "${NAME_PREFIX}-" \
  --state-value ALARM \
  --query 'MetricAlarms[].AlarmName' --output table
# Expect: empty table.
```

**KMS key state + rotation.**

```bash
KMS_ARN="$(terraform output -raw kms_key_arn)"
aws kms describe-key --key-id "$KMS_ARN" \
  --query 'KeyMetadata.{State:KeyState,Manager:KeyManager,DeletionDate:DeletionDate}'
aws kms get-key-rotation-status --key-id "$KMS_ARN"
# Expect: State=Enabled, KeyRotationEnabled=true, no DeletionDate.
```

**Cost-data pipeline freshness.**

```bash
aws cloudwatch get-metric-statistics \
  --namespace FinOps/CostDataExports \
  --metric-name HoursSinceLastCurDelivery \
  --start-time "$(date -d '24 hours ago' -u +%FT%TZ)" \
  --end-time   "$(date -u +%FT%TZ)" \
  --period 3600 --statistics Maximum \
  --query 'Datapoints | sort_by(@,&Timestamp) | [-1].Maximum'
# Expect: < 36.
```

**DDB table PITR + encryption.**

```bash
for t in alerting-events budgets-state idle-findings scheduler-state kpi-snapshots; do
  TBL="${NAME_PREFIX}-${t}"
  PITR=$(aws dynamodb describe-continuous-backups --table-name "$TBL" \
           --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' \
           --output text)
  SSE=$(aws dynamodb describe-table --table-name "$TBL" \
          --query 'Table.SSEDescription.SSEType' --output text)
  printf '%-50s PITR=%s SSE=%s\n' "$TBL" "$PITR" "$SSE"
done
# Expect: PITR=ENABLED SSE=KMS on every row.
```

**No drift on Terraform-managed resources.**

```bash
terraform plan -detailed-exitcode -out=/tmp/plan.bin
# Exit code 0 = no changes. 2 = drift. 1 = error.
```

If any quarterly check fails, file a ticket and resolve before the
next check — don't carry findings forward.

---

## 5. Incident roles + escalation

The framework uses a 4-tier severity matrix. Severity drives paging
behaviour, comms, and which doc you switch to.

| Sev | Definition | Examples | Owner | Comms | Pivot to |
|---|---|---|---|---|---|
| **Sev-1** | Existential / data-loss risk | KMS scheduled for deletion; mass DDB or S3 deletion; any D1–D6 disaster class; confirmed credential leak | Oncall SRE + Security on-call + FinOps lead | PagerDuty page; incident channel; status page if customer-visible | [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) and/or [THREAT_MODEL.md](THREAT_MODEL.md) |
| **Sev-2** | Framework partially down; data flowing but degraded | DLQ depth > 10 on any Lambda; multiple `*-errors` alarms; CUR delivery stale > 72h; allocation coverage WoW drop > 10pp | Oncall SRE | PagerDuty page; incident channel | This runbook §2 |
| **Sev-3** | Single-component issue; no business impact yet | Single Lambda DLQ < 10 messages; single budget breach; tag coverage drift < 5pp | Oncall SRE during hours | Slack alert in `#finops-ops` | This runbook §2 |
| **Sev-4** | Informational / known noise | KPI variance within tolerance; quarterly health-check finding; expected first-of-month true-up spike | FinOps analyst | Ticket only | n/a |

**Roles during an incident.**

- **Incident commander** — owns comms, decides Sev, escalates. Usually
  the oncall SRE.
- **Subject-matter lead** — runs the diagnostic commands. Per-module:
  whoever last touched the module's Terraform.
- **Scribe** — keeps the timeline in the incident channel. Required
  for Sev-1 and Sev-2.

**Escalation rules.**

1. If a Sev-3 has not been mitigated in 4 working hours, raise to Sev-2.
2. If a Sev-2 has not been mitigated in 2 hours, raise to Sev-1.
3. If at any point the symptoms include the CMK, mass-delete, audit-row
   modification, or webhook tampering — raise to Sev-1 and pivot
   without waiting for the timer.

After every Sev-1 and Sev-2: write a post-incident review within 5
business days, file follow-up tickets, and update this runbook if the
symptom-to-resolution path was novel.

---

## 6. Reference

**Companion docs (this repository).**

- [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) — D1–D6 class events,
  per-module RPO / RTO, KMS recovery, DDB PITR restore procedure.
- [THREAT_MODEL.md](THREAT_MODEL.md) — STRIDE assets, trust boundaries,
  per-asset mitigations, detection signals.
- [METRICS_GLOSSARY.md](METRICS_GLOSSARY.md) — exact definitions of
  every `FinOps/*` metric, dimension, unit, and emission cadence.
- [ARCHITECTURE.md](ARCHITECTURE.md) — the framework's data flow,
  control flow, and module boundaries.
- [COMPLIANCE_NOTES.md](COMPLIANCE_NOTES.md) — SOX / PCI / GDPR / DORA
  mapping.
- [EXECUTIVE_BRIEF.md](EXECUTIVE_BRIEF.md) — one-page exec summary for
  leadership comms during a Sev-1/2.

**Per-module edge-case notes** (read before triaging that module):

- `modules/alerting/docs/EDGE_CASES.md`
- `modules/budgets/docs/EDGE_CASES.md`
- `modules/cost-data-exports/docs/EDGE_CASES.md`
- `modules/finops-metrics/docs/EDGE_CASES.md`
- `modules/idle-resource-cleanup/docs/EDGE_CASES.md`
- `modules/instance-scheduler/docs/EDGE_CASES.md`
- `modules/tag-governance/docs/EDGE_CASES.md`

**AWS-side references.**

- **AWS Health Dashboard** — <https://health.aws.amazon.com/health/home>
  — check first for regional outages and service events before
  treating an alarm as framework-side.
- **CloudTrail** — your authoritative audit trail. Lookup events by
  user, resource, or API call:

  ```bash
  aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=ResourceName,AttributeValue="${NAME_PREFIX}-cmk" \
    --max-results 25 \
    | jq '.Events[] | {time:.EventTime, user:.Username, name:.EventName}'
  ```

- **AWS Support** — required path for any AWS-side issue (CUR delivery,
  Budgets billing data, BCM Data Exports). The framework cannot
  remediate AWS-side outages on its own.

**Conventions used throughout this doc.**

- `NAME_PREFIX` defaults to `examplebank-shared-finops` — substitute
  your own.
- All bash blocks assume `set -euo pipefail` and the env vars from §1.
- Every command is read-only or idempotent **unless** explicitly
  flagged as destructive (`purge-queue`, `delete-item`, `delete-table`,
  `put-function-concurrency 0`).
- "Pivot to X" means *stop following this runbook* and switch to the
  named doc — the incident type has changed.
