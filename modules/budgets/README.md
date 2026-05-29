# budgets

A FinOps **budget control plane**, not a stock AWS Budgets wrapper. Polymorphic budget schema, AWS Budget Actions, daily performance Lambda, DynamoDB-backed trend store, CloudWatch dashboard, anomaly-correlated breach alerts.

## What's in the box

| Layer | What it gives you |
|---|---|
| **Polymorphic schema** | One `budgets` map, four scopes (account / service / tag / cost_category) handled by one Terraform resource via `dynamic "cost_filter"` blocks. |
| **Per-budget overrides** | `time_unit` (MONTHLY/QUARTERLY/ANNUALLY), `currency`, custom `thresholds` ladder, `extra_notification_emails`. Production budgets and dev budgets can have different threshold-aggression in the same map. |
| **AWS Budget Actions** | `APPLY_IAM_POLICY` / `APPLY_SCP_POLICY` / `RUN_SSM_DOCUMENTS` auto-enforcement on breach, with `MANUAL` or `AUTOMATIC` approval model. The module provisions the budgets execution role with the right service principal + scoped permissions. |
| **Governance metadata** | Per-budget `owner`, `approver`, `approved_at`, `purpose` → applied as tags AND surfaced in the daily digest so chat-notifier can route to the right person. |
| **Daily performance Lambda** | Reads every Budget in the account, computes VariancePct + ForecastVariancePct + **BurnRateDaysToBreach**, correlates breaches with Cost Anomaly Detection, writes STATE + daily SNAPSHOT rows to DDB. |
| **DDB state + trend table** | `PK = BUDGET#<name>`, `SK = STATE \| SNAPSHOT#<date> \| ACTION#<ts>`. STATE = current; SNAPSHOT = ~13-month daily history; CMK-encrypted, PITR enabled, TTL-managed, `prevent_destroy`. |
| **CloudWatch namespace `FinOps/Budgets`** | `VariancePct` + `ForecastVariancePct` + `BurnRateDaysToBreach` per `Budget` dimension; `BudgetAdherenceScore` + `ActiveBudgetCount` + `ApproachingBreachCount` aggregates. |
| **SSM Parameter Store mirror** | Aggregate KPIs at `/<name_prefix>/budgets/budget_adherence_score`, `/active_budget_count` for cross-workspace consumption. |
| **Auto-provisioned dashboard** | Gauge: adherence score; line: variance % per budget; line: burn-rate days-to-breach per budget; single-value: active budget count. |
| **Alarms** | `BudgetAdherenceScore < threshold` (steering metric), Lambda Errors, DLQ depth. |
| **Anomaly correlation** | Breach + active Cost Anomaly Detection finding in the same period = "investigate" severity (high); plain breach = "tighten the belt" (medium). |

## Inputs

### Core

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for notifications + digests + alarms. |
| `currency` | string | — | ISO 4217 default for budgets without their own currency. |
| `kms_key_arn` | string | — | CMK for log groups, DDB at-rest, Lambda env. |
| `log_retention_days` | number | — | CloudWatch log retention. |
| `lambda_runtime` | string | `"python3.12"` | Python runtime. |
| `default_tags` | map(string) | — | Tags applied to all resources. |

### Performance tracking

| Name | Type | Default | Description |
|---|---|---|---|
| `enable_performance_tracking` | bool | `true` | Deploy the daily Lambda + DDB + dashboard. |
| `performance_schedule_cron` | string | `"0 7 * * ? *"` | EventBridge cron (UTC). |
| `adherence_alarm_threshold` | number | `80` | Alarm if `BudgetAdherenceScore` < this. Null disables. |
| `burn_rate_alarm_days_to_breach` | number | `7` | Reserved for future per-budget metric-math alarm. Null disables. |
| `default_thresholds` | list | `[50/A, 80/A, 100/A, 100/F]` | Ladder applied when a budget doesn't specify its own. |

### Polymorphic `budgets` schema

```hcl
budgets = {
  <key> = {
    scope  = "account" | "service" | "tag" | "cost_category"
    amount = number

    # Optional overrides
    time_unit = "MONTHLY" | "QUARTERLY" | "ANNUALLY"   # default "MONTHLY"
    currency  = "USD" | "EUR" | ...                     # overrides module currency

    target = {                                          # required for non-account
      service        = string
      tag_key        = string
      tag_value      = string
      category_name  = string
      category_value = string
    }

    thresholds = [{ pct = number, type = "ACTUAL" | "FORECASTED" }]
    extra_notification_emails = [string]

    actions = [{
      threshold_pct      = number
      action_type        = "APPLY_IAM_POLICY" | "APPLY_SCP_POLICY" | "RUN_SSM_DOCUMENTS"
      approval_model     = "MANUAL" | "AUTOMATIC"
      # APPLY_IAM_POLICY:
      iam_policy_arn  = arn
      iam_roles       = [string]
      iam_groups      = [string]
      iam_users       = [string]
      # APPLY_SCP_POLICY:
      scp_policy_id   = string
      scp_target_ids  = [string]
      # RUN_SSM_DOCUMENTS:
      ssm_action_subtype = "STOP_EC2_INSTANCES" | "STOP_RDS_INSTANCES"
      ssm_region         = string
      ssm_instance_ids   = [string]
      subscribers        = [string]
    }]

    # Governance metadata
    owner       = string
    approver    = string
    approved_at = string
    purpose     = string
  }
}
```

## Outputs

| Name | Description |
|---|---|
| `budget_ids` | Map of key → AWS Budgets resource ID. |
| `budget_names` | Map of key → budget name. |
| `budget_action_ids` | Map of `<key>-action-<idx>` → Budget Action ID. |
| `state_table_name` | DDB table with per-budget STATE + SNAPSHOT + ACTION rows. |
| `state_table_arn` | DDB table ARN. |
| `performance_lambda_arn` | Daily performance Lambda ARN. |
| `performance_dlq_arn` | Performance Lambda DLQ ARN. |
| `metric_namespace` | `FinOps/Budgets`. |
| `ssm_prefix` | `/<name_prefix>/budgets`. |
| `dashboard_name` | Auto-provisioned CloudWatch dashboard. |
| `budget_actions_role_arn` | Execution role used by AWS Budget Actions (null if none configured). |

## CloudWatch metrics produced

| Metric | Dimensions | Meaning |
|---|---|---|
| `VariancePct` | `Budget` | (actual − limit) ÷ limit × 100 |
| `ForecastVariancePct` | `Budget` | (forecast − limit) ÷ limit × 100 |
| `BurnRateDaysToBreach` | `Budget` | At current burn rate, days until the limit is reached |
| `BudgetAdherenceScore` | — | % of all budgets currently within target |
| `ActiveBudgetCount` | — | Total budgets discovered |
| `ApproachingBreachCount` | — | Budgets with `BurnRateDaysToBreach` < 14 |

## DDB schema

```
PK = "BUDGET#<budget-name>"

SK = "STATE"
    BudgetName, TimeUnit, LimitAmount, ActualSpend, ForecastedSpend,
    VariancePct, ForecastVariancePct, DaysToBreach,
    DaysElapsed, DaysInPeriod, IsAdherent,
    AnomalyCorrelated, AnomalyCountInPeriod,
    LastEvaluatedAt, ExpireAt (~90d after last sighting)

SK = "SNAPSHOT#YYYY-MM-DD"
    Date, LimitAmount, ActualSpend, ForecastedSpend,
    VariancePct, DaysToBreach, IsAdherent, ExpireAt (~13 months)

SK = "ACTION#<iso-ts>"     (optional, written by Budget Action invocations)
    ActionType, ActorId, Outcome, ExpireAt (7y, audit-grade)
```

The 13-month snapshot retention covers year-over-year trend analysis: a BI tool reading the table can compute "December variance over the last 3 years" directly.

## Daily digest payload

The performance Lambda publishes a structured digest to the events bus every day:

```json
{
  "AlertName": "FinOps daily budget performance digest",
  "severity": "info" | "medium" | "high",
  "GeneratedAt": "2026-05-29T07:00:00Z",
  "AdherenceScore": 87.5,
  "ActiveBudgets": 8,
  "AdherentCount": 7,
  "BreachedCount": 1,
  "ApproachingBreachCount": 2,
  "AnomalyActiveThisMonth": true,
  "ActiveAnomalies": 3,
  "TopBreaches": [
    { "Budget": "...", "VariancePct": 14.2, "AnomalyCorrelated": true, ... }
  ],
  "TopApproaching": [
    { "Budget": "...", "DaysToBreach": 4.5, ... }
  ]
}
```

The `chat-notifier` Lambda renders this into Slack/Teams with severity-coloured cards. `TopBreaches` items where `AnomalyCorrelated = true` get an "🔍 investigate" prefix; otherwise "🛑 tighten the belt."

## Design notes

- **Two-source truth**: the budgets themselves are owned by AWS Budgets (so AWS's notification engine and Budget Actions still work); the DDB table is the framework's derived store for trend analysis and audit. Both can be queried; the AWS Budgets API is the source for current state, DDB is the source for history.
- **Anomaly correlation is intentionally simplistic** — it asks "is there ANY active anomaly this month?" rather than trying to match anomaly scope to budget scope. The simpler signal works: a budget breach during anomaly-active periods almost always warrants investigation rather than belt-tightening.
- **Burn-rate calculation is linear** — assumes current burn rate continues. Doesn't model seasonality or weekday/weekend patterns. For tighter forecasts, swap to a Cost Explorer `GetCostForecast` call (already in the Lambda's IAM).
- **Budget Actions APPROVAL_MODEL is `MANUAL` by default** — even with the action provisioned, a human must explicitly approve before AWS executes. To make it fully automatic, set `approval_model = "AUTOMATIC"` per action (and brace yourself).
- **No `prevent_destroy` on AWS Budgets** — budgets are easily recreated from Terraform; only the DDB historical store carries `prevent_destroy` because regenerating 13 months of trend data is impossible.
- **The dashboard scales gracefully** — `metrics = [for k, _ in var.budgets : ...]` produces one line per budget. For accounts with 50+ budgets, consider tightening the variance dashboard to show only the top-N by variance.

## When to extend

- **Slack action-button approvals** for `MANUAL` Budget Actions — requires API Gateway receiver
- **Recommendations Lambda** that looks at 90-day SNAPSHOT history and proposes budget adjustments
- **Multi-account budget rollup** via assume-role from a central account
- **Budget hierarchy** (parent = sum of children) — needs another DDB index + a small reconciliation Lambda
- **Owner-routed digests** — extend chat-notifier to read `BudgetOwner` from the digest and DM via Slack lookup
