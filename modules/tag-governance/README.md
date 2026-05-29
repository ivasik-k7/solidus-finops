# tag-governance

A FinOps-Foundation-aligned tag governance module. Goes beyond "is the tag there?" to answer:

- **Is the tag there?** (Config rule)
- **What does the tag mean?** (`tag_taxonomy` — versioned schema in code)
- **Is the value valid?** (`allowed_values` on the Config managed rule)
- **Who changed it, when?** (`Tag Change on Resource` EventBridge → events bus)
- **How much money is leaking through the tag gap?** (weekly untagged-cost report Lambda)
- **What is our tag-health score, trending?** (CloudWatch metrics + SSM mirror)

**Notify, do not mutate.** Auto-tagging non-compliant resources with placeholder values is deliberately not implemented — it creates unauditable shadow allocation. The right enforcement is **at creation** via IAM/SCP; see [docs/TAG_GOVERNANCE_PATTERNS.md](../../docs/TAG_GOVERNANCE_PATTERNS.md).

## FinOps Foundation Capabilities implemented

| Capability | What this module delivers |
|---|---|
| Policy & Governance | Required-tag Config rule (chunked over the 6-key limit) |
| Allocation | Tag taxonomy as code; allocation Resource Groups |
| Reporting & Analytics | Weekly untagged-cost report; tag-health score |
| FinOps Practice Operations | Tag drift detection on allocation-critical keys |

## Inputs

### Core compliance

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for compliance findings, drift events, reports. |
| `kms_key_arn` | string | — | CMK for the Config bucket + Lambda log group. |
| `log_retention_days` | number | — | CloudWatch log retention for the report Lambda. |
| `lambda_runtime` | string | — | Python runtime for the report Lambda. |
| `required_tags` | list(object{key,allowed_values}) | — | Tags the Config managed rule enforces. Chunked into groups of 6. |
| `resource_types` | list(string) | — | AWS::Service::Resource types the Config rule evaluates. |
| `record_global_resources` | bool | `true` | Include IAM/CloudFront/Route53 in the Config recorder. |
| `enable_config_recorder` | bool | `true` | Set false if Config is already on at the org level. |

### Taxonomy

| Name | Type | Default | Description |
|---|---|---|---|
| `tag_taxonomy` | map(object{level,purpose,description,examples}) | `{}` | Rich metadata per tag key. `level` ∈ {mandatory, recommended, operational}; `purpose` ∈ {allocation, compliance, operational, lifecycle}. When supplied, `level = "mandatory"` entries drive the untagged-cost report's mandatory list; otherwise it falls back to `required_tags`. |

### Drift detection

| Name | Type | Default | Description |
|---|---|---|---|
| `enable_tag_drift_detection` | bool | `true` | EventBridge rule on `aws.tag Tag Change on Resource` → events bus. |
| `tag_drift_watched_keys` | list(string) | `["CostCenter","BusinessUnit","Application"]` | Tag keys whose mutations trigger an audit event. |

### Untagged-cost report

| Name | Type | Default | Description |
|---|---|---|---|
| `enable_untagged_cost_report` | bool | `false` | Deploy weekly Lambda that dollarizes the tag gap. Requires Athena workgroup + CUR table. |
| `untagged_cost_report_cron` | string | `"0 8 ? * MON *"` | EventBridge cron (UTC). |
| `untagged_cost_alarm_threshold_usd` | number | `1000` | Alarm if total untagged cost (current month) exceeds this. Null disables. |
| `untagged_cost_top_n` | number | `20` | Number of top-cost untagged resources surfaced in each report. |
| `athena_workgroup_name` | string | `null` | Athena workgroup for the report queries. |
| `athena_database_name` | string | `null` | Glue database holding the CUR table. |
| `cur_table_name` | string | `"cur2"` | Glue table name for CUR 2.0. |

### Allocation Resource Groups

| Name | Type | Default | Description |
|---|---|---|---|
| `allocation_resource_groups` | map(object{tag_key,tag_values}) | `{}` | Map of group name → tag filter. Provisions `aws_resourcegroups_group` resources so the Console can filter by BU/CostCenter/Environment out-of-the-box. |

| `default_tags` | map(string) | — | Tags applied to every resource in the module. |

## Outputs

| Name | Description |
|---|---|
| `config_rule_names` | List of Config rule names (one per 6-tag chunk). |
| `config_bucket` | Config delivery bucket name (null if recorder disabled). |
| `tag_drift_event_rule_name` | EventBridge rule name capturing allocation-tag mutations. |
| `allocation_resource_group_arns` | Map of allocation-group name → ARN. |
| `untagged_cost_lambda_arn` | ARN of the untagged-cost report Lambda (null if disabled). |
| `untagged_cost_dlq_arn` | SQS DLQ ARN for the report Lambda. |
| `metric_namespace` | CloudWatch namespace (`FinOps/TagGovernance`). |
| `ssm_prefix` | SSM Parameter Store path prefix (`/<name_prefix>/tag-governance`). |
| `mandatory_tag_keys` | Resolved mandatory tag keys. |

## What it produces

### CloudWatch metrics (namespace `FinOps/TagGovernance`)

| Metric | Dimensions | Meaning |
|---|---|---|
| `TagCoveragePct` | `TagKey` | % of unblended cost carrying this tag (per mandatory key, current month) |
| `UntaggedCostUsd` | `MissingTagKey` | $ cost of resources missing this tag, current month |
| `TotalUntaggedCostUsd` | — | Sum of all per-tag gap costs |
| `TopUntaggedResourceMaxCostUsd` | — | Cost of the single most-expensive untagged resource |
| `TagHealthScore` | — | Composite 0–100 score: weighted average of `avg(coverage) × 3 + (100 − gap_penalty) × 1`, where `gap_penalty = min(100, total_untagged_cost / 10 000 × 100)`. Higher is better. |

### SSM Parameter Store (`/<name_prefix>/tag-governance/*`)

Scalar metrics mirror under `total_untagged_cost_usd`, `tag_health_score`, etc. Other Terraform workspaces can read these without state sharing.

### Built-in alarms (all route to the events bus)

| Alarm | Fires when |
|---|---|
| `<prefix>-untagged-cost-errors` | Report Lambda errors > 0 |
| `<prefix>-untagged-cost-dlq-depth` | DLQ message visible |
| `<prefix>-untagged-cost-excess` | `TotalUntaggedCostUsd` exceeds `untagged_cost_alarm_threshold_usd` |

### Event-bus messages

- **`FinOps tag non-compliance`** — Config rule moved a resource to `NON_COMPLIANT` (existing behavior).
- **`FinOps allocation-tag mutation`** — A watched tag key was created, modified, or deleted on any resource. Payload includes account, region, resource ARN, changed keys, and the new tag values.
- **`FinOps weekly tag-governance digest`** — The report Lambda's output: per-tag coverage %, per-tag gap $, top-N untagged resources, health score.

## Design notes

- **Tag taxonomy is additive metadata.** The `required_tags` variable still drives the Config managed rule. The taxonomy adds level/purpose semantics that the untagged-cost Lambda and the README consume. You can use taxonomy alone (then `level = "mandatory"` entries imply `required_tags`) or both.
- **The Config managed rule's `allowed_values`** is the only value-validation layer available without a custom Lambda rule. Regex / fuzzy-match value validation is a future enhancement.
- **Drift detection uses `aws.tag`**, AWS's unified EventBridge event for tag mutations. It covers most common services (EC2, RDS, S3, Lambda, ELB, DynamoDB, IAM roles, EKS, ECS) but is not 100% of all AWS services — a small number of older or specialized services don't emit this event. For audit-critical coverage, complement with CloudTrail `tag:TagResources` / `tag:UntagResources` filters.
- **The untagged-cost Lambda runs Athena queries against the CUR.** It needs at least one month of CUR delivery to produce meaningful numbers — defer turning it on until you're in the "Walk" phase (see [docs/PHASES.md](../../docs/PHASES.md)).
- **Resource Groups are tag-based.** They update automatically as tags change; no Lambda needed.
- **No `prevent_destroy`.** The reports and groups are derived data — recoverable.

## When you outgrow this module

Three escalations worth considering, in order:

1. **Custom Config rules for value validation** (regex / case sensitivity / typo detection) — a Lambda-backed Config rule per high-value tag.
2. **Service Catalog products + tag inheritance** — push tag defaults to the provisioning layer instead of the validation layer.
3. **Account-level IAM SCP/permission boundary** that fails any resource-creation call missing the mandatory tag keys. See [docs/TAG_GOVERNANCE_PATTERNS.md](../../docs/TAG_GOVERNANCE_PATTERNS.md). This is the only tag enforcement that prevents non-compliance — everything else detects it after the fact.
