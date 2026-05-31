###############################################################################
# Variables — input contract
###############################################################################

# ---------------------------------------------------------------------------
# Required plumbing
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix applied to every resource. Recommend: <namespace>-<environment>."
  type        = string
}

variable "events_topic_arn" {
  description = "SNS topic ARN for budget threshold breaches + Lambda alarm actions + performance digests. Required."
  type        = string
}

variable "currency" {
  description = "ISO 4217 currency code applied to all budgets (per-budget currency can override)."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Encrypts the DDB state table + performance Lambda log group + env vars."
  type        = string
}

variable "default_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for the performance Lambda. Validated to >= 365 (Checkov CKV_AWS_338)."
  type        = number

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the performance Lambda."
  type        = string
  default     = "python3.12"
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the performance Lambda."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the performance Lambda. Null = no reservation."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Budgets — polymorphic
# ---------------------------------------------------------------------------

variable "budgets" {
  description = <<-EOT
    Polymorphic budget definitions. Per-budget overrides allow custom
    thresholds, time_unit, currency, notification recipients, AWS Budget
    Actions (IAM/SCP/SSM), and governance metadata.
  EOT
  type = map(object({
    # Required
    scope  = string # "account" | "service" | "tag" | "cost_category"
    amount = number

    # Optional period + currency overrides
    time_unit = optional(string, "MONTHLY") # MONTHLY | QUARTERLY | ANNUALLY
    currency  = optional(string, null)      # overrides module's currency

    # Filter target (required for non-account scope)
    target = optional(object({
      service        = optional(string)
      tag_key        = optional(string)
      tag_value      = optional(string)
      category_name  = optional(string)
      category_value = optional(string)
    }))

    # Custom thresholds. Empty = use default_thresholds.
    thresholds = optional(list(object({
      pct  = number
      type = optional(string, "ACTUAL") # ACTUAL | FORECASTED
    })), [])

    # Per-budget extra email subscribers (in addition to events topic)
    extra_notification_emails = optional(list(string), [])

    # AWS Budget Actions (auto-enforcement on threshold breach)
    actions = optional(list(object({
      threshold_pct     = number
      notification_type = optional(string, "ACTUAL") # ACTUAL | FORECASTED
      action_type       = string                     # APPLY_IAM_POLICY | APPLY_SCP_POLICY | RUN_SSM_DOCUMENTS
      approval_model    = optional(string, "MANUAL") # MANUAL | AUTOMATIC

      # APPLY_IAM_POLICY
      iam_policy_arn = optional(string)
      iam_roles      = optional(list(string), [])
      iam_groups     = optional(list(string), [])
      iam_users      = optional(list(string), [])

      # APPLY_SCP_POLICY
      scp_policy_id  = optional(string)
      scp_target_ids = optional(list(string), [])

      # RUN_SSM_DOCUMENTS
      ssm_action_subtype = optional(string) # STOP_EC2_INSTANCES | STOP_RDS_INSTANCES
      ssm_region         = optional(string)
      ssm_instance_ids   = optional(list(string), [])

      # Per-action email subscribers
      subscribers = optional(list(string), [])
    })), [])

    # Governance metadata
    owner       = optional(string, "(unowned)")
    approver    = optional(string, "")
    approved_at = optional(string, "")
    purpose     = optional(string, "")
  }))

  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["account", "service", "tag", "cost_category"], v.scope)
    ])
    error_message = "budgets.*.scope must be one of: account, service, tag, cost_category."
  }
  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["MONTHLY", "QUARTERLY", "ANNUALLY"], v.time_unit)
    ])
    error_message = "budgets.*.time_unit must be one of: MONTHLY, QUARTERLY, ANNUALLY."
  }
  validation {
    condition     = alltrue([for k, v in var.budgets : v.amount > 0])
    error_message = "budgets.*.amount must be > 0."
  }
}

variable "default_thresholds" {
  description = "Threshold ladder applied to any budget that doesn't specify its own."
  type = list(object({
    pct  = number
    type = optional(string, "ACTUAL")
  }))
  default = [
    { pct = 50, type = "ACTUAL" },
    { pct = 80, type = "ACTUAL" },
    { pct = 100, type = "ACTUAL" },
    { pct = 100, type = "FORECASTED" },
  ]
}

# ---------------------------------------------------------------------------
# Performance tracking + alarms
# ---------------------------------------------------------------------------

variable "enable_performance_tracking" {
  description = "Deploy the daily budget-performance Lambda (variance, burn-rate, adherence score, DDB trend, dashboard)."
  type        = bool
  default     = true
}

variable "performance_schedule_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the performance Lambda."
  type        = string
  default     = "0 7 * * ? *"
}

variable "adherence_alarm_threshold" {
  description = "Alarm if BudgetAdherenceScore drops below this (% of budgets within target). Null disables."
  type        = number
  default     = 80
}

variable "burn_rate_alarm_days_to_breach" {
  description = "Alarm if any budget's BurnRateDaysToBreach drops below this. Null disables."
  type        = number
  default     = 7
}
