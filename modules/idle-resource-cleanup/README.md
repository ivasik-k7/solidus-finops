# idle-resource-cleanup

A FinOps control plane for idle / leaked / orphaned AWS resources. **Six resource types, multi-region, lifecycle-aware, auditable.**

This is not a "scan + report" Lambda. It's a stateful pipeline:

```
detect → upsert state in DDB → check actionable (snooze/exception) → act
                                                         ↓
                                                    audit-log row
                                                    + CloudWatch metric
                                                    + Slack/Teams digest
```

## Game-changing capabilities

| Capability | What it gives the FinOps practice |
|---|---|
| **DynamoDB-backed lifecycle state** | Findings dedup across runs (no weekly spam); aging escalation (seen ≥ 10 weeks → severity bumped); snooze + exception management; sortable by status via a GSI |
| **Append-only audit log** | Every mutation (`detected`, `snapshotted`, `deleted`, `released`, `rollback`, `skipped-ceiling`) lands in DDB with actor ID + timestamp + saved $. 7-year TTL by default. Auditor-grade trail. |
| **Cumulative savings tracker** | Every actual deletion increments per-Lambda `RunSavingsUsd` metric. Sum over time = the practice's savings curve, on the dashboard. |
| **Multi-region scanning** | Each Lambda iterates `scan_regions`. Catches the typical "we forgot about ap-southeast-1" cost gap. |
| **Auto-provisioned CloudWatch dashboard** | Six widgets covering waste-by-type, savings curve, found-count trend, Lambda errors, DLQ depth. One link the FinOps lead sends to leadership. |
| **Two-phase EBS deletion** | Snapshot in run N, delete in run N+1 after grace + completion check. No race. Configurable rollback window. |
| **Per-resource enable flags + schedules** | Each of six types has its own toggle + cron. No more dogpile-on-Monday scans. |
| **Per-Lambda cost ceiling** | Caps `$ value acted on per run`. Misfires can't cascade. NAT/LB defaults are intentionally conservative ($100). |
| **Six resource types in one module** | EBS volumes, EBS snapshots, Elastic IPs, NAT Gateways, ENIs, Load Balancers (ALB/NLB/CLB). Same lifecycle pattern for all. |
| **Shared `idle_state.py` helper, bundled per Lambda** | All Lambdas share the same DDB-state lifecycle code. Adding a new resource type = ~150 lines of `process()` Python. |

## Inputs

### Core

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for digests + alarms. |
| `kms_key_arn` | string | — | CMK for log groups, Lambda env vars, **DynamoDB table**. |
| `log_retention_days` | number | — | CloudWatch log retention. |
| `lambda_runtime` | string | — | Python runtime. |
| `default_tags` | map(string) | — | Tags applied to every resource. |
| `dry_run` | bool | `true` | Every Lambda only reports. |
| `exception_tag_key` | string | `"FinOpsException"` | Tag key that excludes a resource. |
| `cost_ceiling_usd` | number | `10000` | Max monthly USD any single Lambda acts on per invocation. |
| `total_waste_alarm_threshold_usd` | number | `500` | Alarm if combined `MonthlyWasteUsd` exceeds this. |

### State lifecycle

| Name | Default | Description |
|---|---|---|
| `aging_seen_count_threshold` | `10` | A finding seen this many consecutive scans is "aging" → severity bumped to high. |
| `findings_ttl_days` | `90` | STATE row retention after a finding stops appearing. |
| `actions_ttl_days` | `2557` | ACTION row retention (7y default for audit-grade trail). |

### Multi-region

| Name | Default | Description |
|---|---|---|
| `scan_regions` | `[]` | Regions each Lambda iterates. Empty = home region only. |

### Per-resource enable flags

| Name | Default |
|---|---|
| `enable_ebs_cleanup` / `enable_eip_cleanup` / `enable_snapshot_cleanup` / `enable_nat_cleanup` / `enable_eni_cleanup` / `enable_lb_cleanup` | all `true` |

### Per-resource thresholds + schedules

See [main.tf](main.tf) — each resource type has its own age, lookback, threshold, and cron. Defaults stagger schedules across Monday hours so they don't dogpile.

## Outputs

| Name | Description |
|---|---|
| `lambda_arns` | Map of type → Lambda ARN. |
| `dlq_arns` | Map of type → SQS DLQ ARN. |
| `schedule_rule_names` | Map of type → EventBridge rule name. |
| `metric_namespace` | `FinOps/IdleResources`. |
| `enabled_resource_types` | Types actively scanned. |
| `findings_table_name` | DynamoDB table holding STATE + ACTION rows. |
| `findings_table_arn` | DynamoDB ARN. |
| `dashboard_name` | Auto-provisioned CloudWatch dashboard. |
| `scan_regions` | Regions each Lambda iterates. |

## DynamoDB schema

Single table, composite key:

```
PK = "<ResourceType>#<ResourceId>"   e.g. "EBS#vol-0abc1234"
SK = "STATE"  | "ACTION#<iso-ts>"
```

**STATE row** — current lifecycle state for one resource:
- `ResourceType`, `ResourceId`, `Region`, `AccountId`
- `FirstSeenAt`, `LastSeenAt`, `SeenCount`
- `Status`: `"new"` | `"aging"` | `"snoozed"` | `"excepted"` | `"approved"` | `"deleted"`
- `StatusUntil` (only when snoozed)
- `EstimatedMonthlyCostUsd`, `Owner`, `Tags`, `ResourceAttrs`
- `ExpireAt` — TTL (auto-cleanup after `findings_ttl_days`)

**ACTION row** — append-only audit-log entry:
- `ActionType`: `"detected"` | `"snapshotted"` | `"deleted"` | `"released"` | `"skipped-ceiling"` | `"rollback"`
- `ActorId`: `"lambda:<function-name>"` or `"human:<iam-user>"` (for manual interventions)
- `Timestamp`, `EstimatedSavingsUsd`, `Notes`
- `ExpireAt` — TTL (`actions_ttl_days`, default 7y)

**GSI `ByStatus`** projects everything keyed by `Status` — instantly answer "show me everything currently snoozed / excepted / approved-for-delete."

## Lifecycle transitions

```
                  detected
       (none) ─────────────────► STATE.Status = "new"
                                       │
                       seen N more times
                                       ▼
                                  "aging"  (severity bumped)
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
       human: snooze            human: except            Lambda: delete OK
              ▼                        ▼                        ▼
         "snoozed"                "excepted"               "deleted"
              │                        │
        StatusUntil elapsed            │
              ▼                        ▼
          "aging"               (terminal, but
                                 still re-detected
                                 each scan; status
                                 holds the row alive)
```

A finding only transitions to a state via either the Lambda (detected, aging, deleted) or a human-initiated DDB write (snoozed, excepted, approved). The Lambda **never** writes terminal states for resources it didn't act on.

## CloudWatch metrics (namespace `FinOps/IdleResources`)

| Metric | Dimensions | Meaning |
|---|---|---|
| `MonthlyWasteUsd` | `ResourceType` | $ value of resources flagged this scan |
| `FoundCount` | `ResourceType` | Number flagged |
| `ActionsTakenCount` | `ResourceType` | Number actually mutated (always 0 in dry-run) |
| `RunSavingsUsd` | `ResourceType` | $ saved on this run (i.e. `MonthlyWasteUsd × ActionsTakenCount / FoundCount`, approximately) |

Aggregate alarm uses Metric Math `SUM(MonthlyWasteUsd ResourceType=*)` vs `total_waste_alarm_threshold_usd`.

## Human-in-the-loop workflows

Because the DDB table is the source of truth, humans can intervene by editing rows directly:

- **Snooze a finding for 30 days**: update STATE row → `Status = "snoozed"`, `StatusUntil = "2026-06-28T00:00:00Z"`.
- **Mark a finding as excepted**: update STATE row → `Status = "excepted"`.
- **Approve a specific resource for deletion**: update STATE row → `Status = "approved"` (the Lambda treats this same as `aging`).
- **Audit who deleted what**: query the GSI for `Status = "deleted"`, or `Query` the table on `PK = "<Type>#<Id>"` to get the full STATE + ACTION timeline of one resource.

## Operational notes

- **First apply**: the DDB table is created empty. The first scan populates it. The dashboard works immediately but lights up with data after the first cycle.
- **Multi-region cost**: each region adds a `DescribeXxx` call cycle per Lambda. Free under typical fleet sizes.
- **Adding a new resource type**: write a Python file under `lambda/<type>/`, add an entry to `local.catalog`, add IAM statements to `local.iam_statements`, and the rest (DLQ, alarm, schedule, dashboard widget) is auto-generated by `for_each`.

## When you outgrow this module

- Slack-button approval workflow (`Approve` / `Snooze 30d` / `Mark Exception`) — requires API Gateway receiver Lambda
- AWS Pricing API for precise region-aware costs (current hardcoded rates are good-enough)
- Step Functions orchestration for cross-Lambda workflows
- Multi-account fan-out via assume-role
- Cross-resource graph reasoning (e.g. "NAT GW + Route + EIP + ENI in same VPC are one decision")
