###############################################################################
# Variables — input contract
###############################################################################

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix applied to every resource. Recommend: <namespace>-<environment>."
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket that holds CUR + FOCUS data. Must be globally unique."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Encrypts the cost-data + athena-results buckets, the Glue crawler's SSE-KMS configuration, the health-check Lambda's log group + env vars."
  type        = string
}

variable "account_id" {
  description = "The AWS account ID this module runs in. Wired into bucket policy conditions."
  type        = string
}

variable "enable_focus_export" {
  description = "Emit a FOCUS 1.0 export alongside CUR 2.0."
  type        = bool
}

variable "enable_athena_workgroup" {
  description = "Provision the Glue database, crawler, Athena workgroup, and (optionally) named-query library."
  type        = bool
}

variable "cost_data_retention_days" {
  description = "Days to keep current CUR/FOCUS objects in S3 Standard before tiering to GLACIER_IR. 0 disables tiering."
  type        = number
}

variable "cost_data_expiration_days" {
  description = "Total days to keep current cost-data objects before expiration. Banks: 2555 (7y) for SOX/PCI."
  type        = number
}

variable "default_tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
}

# ---------------------------------------------------------------------------
# Optional integrations
# ---------------------------------------------------------------------------

variable "events_topic_arn" {
  description = "Optional SNS topic for CUR / crawler / health-check events. Null disables EventBridge integration + skips health-check digest publishing."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the health-check Lambda. Validated to >= 365 (Checkov CKV_AWS_338)."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the health-check Lambda."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the health-check Lambda. Null = no reservation."
  type        = number
  default     = null
}

variable "lambda_runtime" {
  description = "Python runtime for the health-check Lambda."
  type        = string
  default     = "python3.12"
}

# ---------------------------------------------------------------------------
# Cross-account reader IAM roles (Cloudability / Vantage / etc.)
# ---------------------------------------------------------------------------

variable "cross_account_readers" {
  description = <<-EOT
    Cross-account IAM roles for 3rd-party FinOps tools to assume and read CUR.

    Each entry creates an IAM role that:
      - Trusts the foreign account (account_id), with optional external_id condition
      - Grants read-only access to the cost-data bucket + Glue catalog + KMS key
      - Optionally grants Athena query permissions (enable_athena = true)

    Example for Cloudability:
      cross_account_readers = [{
        name          = "cloudability"
        account_id    = "165761016623"
        external_id   = var.cloudability_external_id
        enable_athena = false
      }]
  EOT
  type = list(object({
    name          = string
    account_id    = string
    external_id   = optional(string, null)
    role_name     = optional(string, null)
    enable_athena = optional(bool, false)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.cross_account_readers : can(regex("^\\d{12}$", r.account_id))])
    error_message = "cross_account_readers[*].account_id must be a 12-digit AWS account ID."
  }
}

# ---------------------------------------------------------------------------
# Health-check Lambda
# ---------------------------------------------------------------------------

variable "enable_health_check" {
  description = "Deploy the daily health-check Lambda (verifies CUR delivery + crawler success + Athena queryability)."
  type        = bool
  default     = true
}

variable "health_check_schedule_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the health-check Lambda."
  type        = string
  default     = "0 9 * * ? *"
}

variable "cur_freshness_alarm_hours" {
  description = "Alarm if the most-recent CUR delivery is older than this. Null disables."
  type        = number
  default     = 36
}

# ---------------------------------------------------------------------------
# Athena named queries
# ---------------------------------------------------------------------------

variable "enable_named_queries" {
  description = "Register the pre-built FinOps Athena named-queries library in the workgroup."
  type        = bool
  default     = true
}

variable "extra_named_queries" {
  description = "Additional Athena named queries to register alongside the built-in library. Map of friendly name → { description, query }."
  type = map(object({
    description = string
    query       = string
  }))
  default = {}
}
