###############################################################################
# Variables — input contract
#
# Grouped by purpose. Required variables have no default; every other variable
# has a sensible production default + a description.
###############################################################################

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix applied to every resource (DDB table, Lambda, IAM, SQS, alarms, dashboard, named queries, SSM parameters). Recommend: <namespace>-<environment>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.name_prefix))
    error_message = "name_prefix must be 2-63 chars, lowercase letters, digits, and hyphens; must start with a letter or digit."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Used to encrypt the DDB snapshot table, Lambda env vars, and CloudWatch log group. Required."
  type        = string
}

variable "athena_workgroup_name" {
  description = "Athena workgroup the named queries register against and the aggregator Lambda submits to. Typically comes from the cost-data-exports module output."
  type        = string
}

variable "athena_database_name" {
  description = "Glue database holding the CUR table."
  type        = string
}

# ---------------------------------------------------------------------------
# Optional plumbing (with defaults)
# ---------------------------------------------------------------------------

variable "events_topic_arn" {
  description = "SNS topic ARN for the daily KPI digest + alarm actions. NULL is valid — in standalone mode the module still emits CloudWatch metrics, writes DDB snapshots, populates SSM, and runs the dashboard. SNS publishes are skipped and alarms run without alarm_actions."
  type        = string
  default     = null

  validation {
    condition     = var.events_topic_arn == null || can(regex("^arn:aws[a-z0-9-]*:sns:[a-z0-9-]+:\\d{12}:.+$", var.events_topic_arn))
    error_message = "events_topic_arn must be a valid SNS topic ARN or null."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the aggregator Lambda log group. Match your org's compliance posture (365 / 1827 / 2557)."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338 floor)."
  }
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the aggregator Lambda. Adds IAM permissions + the tracing_config block."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the aggregator Lambda. Null = no reservation."
  type        = number
  default     = null
}

variable "lambda_runtime" {
  description = "Python runtime for the aggregator Lambda."
  type        = string
  default     = "python3.12"

  validation {
    condition     = can(regex("^python3\\.(1[0-9]|2[0-9])$", var.lambda_runtime))
    error_message = "lambda_runtime must be a supported Python runtime (python3.10..python3.29)."
  }
}

variable "default_tags" {
  description = "Tags applied to every resource this module creates. Empty default keeps the module standalone-reusable."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# CUR + Athena query schema
# ---------------------------------------------------------------------------

variable "cur_table_name" {
  description = "Glue table name for the CUR 2.0 export. The aggregator queries <athena_database_name>.<cur_table_name>. cost-data-exports defaults to 'cur2'."
  type        = string
  default     = "cur2"
}

variable "allocation_tag_keys" {
  description = "Tag keys treated as 'allocation tags'. A CUR line counts as allocated only if it carries all of these. Typically [CostCenter, BusinessUnit, Application]. Pass an empty list to disable the allocation_coverage KPI entirely."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

# ---------------------------------------------------------------------------
# Schedule
# ---------------------------------------------------------------------------

variable "aggregator_cron" {
  description = "EventBridge cron expression (UTC, six-field) for the daily KPI aggregator."
  type        = string
  default     = "0 7 * * ? *"
}

# ---------------------------------------------------------------------------
# Built-in KPIs — per-KPI enable map
# ---------------------------------------------------------------------------

variable "builtin_kpis_enabled" {
  description = <<-EOT
    Per-KPI enable map for the built-in KPIs. Set any key to false to skip
    that KPI entirely (no metric, no DDB snapshot, no alarm). Useful when
    upstream tooling already provides a value:

      - allocation_coverage    — set false if Cloudability owns this
      - commitment_coverage    — set false if Cloudability owns this
      - commitment_utilization — set false if Cloudability owns this
      - anomaly_impact         — set false if Cloudability owns this
      - forecast_drift         — set false if Cloudability owns this
      - spend_by_service       — top-N service spend with Service dimension
  EOT
  type = object({
    allocation_coverage    = optional(bool, true)
    commitment_coverage    = optional(bool, true)
    commitment_utilization = optional(bool, true)
    anomaly_impact         = optional(bool, true)
    forecast_drift         = optional(bool, true)
    spend_by_service       = optional(bool, true)
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Custom KPIs — user-defined Athena KPIs
# ---------------------------------------------------------------------------

variable "custom_kpis" {
  description = <<-EOT
    User-defined KPIs. Each entry is registered as an Athena named query AND
    executed by the aggregator Lambda, emitted as a CloudWatch metric, written
    to a DDB snapshot row, and optionally alarmed on.

    The SQL MUST return a single row with a single numeric column. Multi-row
    or multi-column queries are skipped with a WARN.

    Example:
      custom_kpis = {
        cost_per_transaction = {
          description = "Account spend divided by daily transaction count"
          sql = <<-SQL
            SELECT ROUND(SUM(line_item_unblended_cost) / 100000.0, 4)
            FROM \$${cur}
            WHERE billing_period = date_format(current_date, '%Y-%m')
          SQL
          unit  = "None"
          alarm = {
            comparison = "GreaterThan"   # or LessThan
            threshold  = 0.50
          }
        }
      }

    Substitutions available in `sql`:
      \$${cur}      → fully-qualified CUR table (athena_database.cur_table_name)
      \$${db}       → athena_database_name
      \$${prefix}   → name_prefix
  EOT
  type = map(object({
    description = optional(string, "")
    sql         = string
    unit        = optional(string, "None")
    alarm = optional(object({
      comparison = string
      threshold  = number
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.custom_kpis : v.alarm == null ||
      contains(["GreaterThan", "GreaterThanOrEqualTo", "LessThan", "LessThanOrEqualTo"], v.alarm.comparison)
    ])
    error_message = "custom_kpis.*.alarm.comparison must be one of: GreaterThan, GreaterThanOrEqualTo, LessThan, LessThanOrEqualTo."
  }

  validation {
    condition = alltrue([
      for k, v in var.custom_kpis : can(regex("^[a-z][a-z0-9_]{1,48}$", k))
    ])
    error_message = "custom_kpis keys must be 2-49 chars, lowercase letters/digits/underscores, starting with a letter (used as metric names + SSM paths)."
  }
}

# ---------------------------------------------------------------------------
# KPI history (DDB) + trend metrics
# ---------------------------------------------------------------------------

variable "snapshot_retention_days" {
  description = "Days to keep daily KPI snapshots in DDB. Drives moving-average + drift compute. 90+ recommended (need enough history for a 30d moving average + month-over-month comparison)."
  type        = number
  default     = 400

  validation {
    condition     = var.snapshot_retention_days >= 35
    error_message = "snapshot_retention_days must be >= 35 (need a full 30d window + slack for the trend metrics to be meaningful)."
  }
}

variable "trend_metrics_enabled" {
  description = "Emit derived trend metrics alongside each base KPI: <Metric>_7dAvg, <Metric>_30dAvg, and <Metric>_WoWDriftPct (this week's avg vs last week's avg). Requires DDB history."
  type        = bool
  default     = true
}

variable "wow_drift_alarm_threshold_pct" {
  description = "Alarm if the week-over-week drift of allocation_coverage exceeds this %. Null disables the alarm. Independent of the absolute-threshold alarms."
  type        = number
  default     = 5
}

# ---------------------------------------------------------------------------
# Auto per-tag-value dashboard
# ---------------------------------------------------------------------------

variable "tag_value_dashboard_tag" {
  description = "If set, the aggregator queries Athena for distinct values of this tag key, emits a SpendByTagValueUsd metric per value, and rebuilds the dashboard with one widget per value. Typical choices: BusinessUnit, CostCenter, Application. Null disables this feature."
  type        = string
  default     = null
}

variable "tag_value_dashboard_top_n" {
  description = "Maximum number of tag values to render as individual dashboard widgets. Values are sorted by current-month cost. 0 disables widget rendering even when tag_value_dashboard_tag is set (metrics still emitted)."
  type        = number
  default     = 12

  validation {
    condition     = var.tag_value_dashboard_top_n >= 0 && var.tag_value_dashboard_top_n <= 30
    error_message = "tag_value_dashboard_top_n must be between 0 and 30 (CloudWatch dashboard practical limit)."
  }
}

# ---------------------------------------------------------------------------
# Absolute-threshold alarms (legacy, kept for compatibility)
# ---------------------------------------------------------------------------

variable "alarm_thresholds" {
  description = <<-EOT
    Per-KPI absolute-threshold alarms. Set any key to null to skip that alarm.

      - allocation_coverage_min_pct     : alarm if below this %
      - commitment_coverage_min_pct     : alarm if below this %
      - commitment_utilization_min_pct  : alarm if below this %
      - forecast_accuracy_max_drift_pct : alarm if drift exceeds this %
  EOT
  type = object({
    allocation_coverage_min_pct     = optional(number, 80)
    commitment_coverage_min_pct     = optional(number, 70)
    commitment_utilization_min_pct  = optional(number, 80)
    forecast_accuracy_max_drift_pct = optional(number, 15)
  })
  default = {}
}
