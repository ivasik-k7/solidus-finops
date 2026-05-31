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
  description = "Prefix applied to every resource (SNS topic, secrets, DDB, Lambda, IAM, alarms). Recommend: <namespace>-<environment>."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Encrypts the SNS topic, every Secrets Manager secret, the DDB events table, and the dispatcher Lambda's env vars + log group. Required."
  type        = string
}

# ---------------------------------------------------------------------------
# Optional plumbing (with defaults)
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for the dispatcher Lambda log group. Validated to >= 365 (Checkov CKV_AWS_338 + most audit regimes)."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338 — and most audit regimes require 1y+). Drop the variable in your root composition if you really need less."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the dispatcher Lambda."
  type        = string
  default     = "python3.12"
}

variable "default_tags" {
  description = "Tags applied to every resource this module creates. Empty default keeps the module standalone-reusable."
  type        = map(string)
  default     = {}
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the dispatcher Lambda. Adds the IAM permissions + the tracing_config block. ~$0.0001 per 100k traces — effectively free at this volume."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the dispatcher Lambda. Null = no reservation (default). Set to a positive integer to cap concurrency, or -1 to disable invocations entirely."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Legacy inputs — synthesised into `channels` only when `channels` is empty.
# Prefer the polymorphic `channels` schema for new deployments.
# ---------------------------------------------------------------------------

variable "notification_emails" {
  description = "Legacy: emails for SNS subscription. Prefer channels.email."
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Legacy single-Slack-webhook. Prefer channels.slack."
  type        = string
  default     = null
  sensitive   = true
}

variable "teams_webhook_url" {
  description = "Legacy single-Teams-webhook. Prefer channels.teams."
  type        = string
  default     = null
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Multi-channel polymorphic schema
# ---------------------------------------------------------------------------

variable "channels" {
  description = <<-EOT
    Multi-channel destination configuration. Each channel-type list holds 0+
    destinations, each with its own min_severity filter.

    Severities (ascending): info | low | medium | high | critical
    A channel with min_severity = "high" only receives alerts of severity
    high or critical.

    For each destination you can pass either:
      - the inline secret value (webhook_url, integration_key, api_key) —
        the module will create a Secrets Manager secret and reference its ARN
      - or *_secret_arn — point at an existing secret you manage elsewhere

    Example:
      channels = {
        slack = [
          { webhook_url = "https://hooks.slack.com/services/...", label = "#finops",    min_severity = "info" },
          { webhook_url = "https://hooks.slack.com/services/...", label = "#incidents", min_severity = "high" },
        ]
        pagerduty = [
          { integration_key = "abc...", label = "finops-oncall", min_severity = "high" },
        ]
        email = [
          { addresses = ["finops@example.com"], min_severity = "info" },
        ]
      }
  EOT
  type = object({
    email = optional(list(object({
      addresses    = list(string)
      min_severity = optional(string, "info")
    })), [])

    slack = optional(list(object({
      webhook_url        = optional(string)
      webhook_secret_arn = optional(string)
      label              = optional(string, "slack")
      min_severity       = optional(string, "info")
    })), [])

    teams = optional(list(object({
      webhook_url        = optional(string)
      webhook_secret_arn = optional(string)
      label              = optional(string, "teams")
      min_severity       = optional(string, "info")
    })), [])

    pagerduty = optional(list(object({
      integration_key            = optional(string)
      integration_key_secret_arn = optional(string)
      label                      = optional(string, "pagerduty")
      min_severity               = optional(string, "high")
    })), [])

    opsgenie = optional(list(object({
      api_key            = optional(string)
      api_key_secret_arn = optional(string)
      label              = optional(string, "opsgenie")
      eu_region          = optional(bool, false)
      min_severity       = optional(string, "high")
    })), [])

    generic_webhooks = optional(list(object({
      url            = optional(string)
      url_secret_arn = optional(string)
      label          = string
      headers        = optional(map(string), {})
      min_severity   = optional(string, "info")
    })), [])

    sqs = optional(list(object({
      queue_arn    = string
      label        = optional(string, "sqs")
      min_severity = optional(string, "info")
    })), [])
  })
  default = {}

  validation {
    condition = alltrue(concat(
      [for c in coalesce(var.channels.slack, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.teams, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.pagerduty, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.opsgenie, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.email, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.generic_webhooks, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.sqs, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
    ))
    error_message = "channels.*.min_severity must be one of: info, low, medium, high, critical."
  }
}

# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

variable "deduplication" {
  description = <<-EOT
    Deduplication cache config. When two events with the same fingerprint
    land within `window_minutes`, the second is suppressed (still audited).
  EOT
  type = object({
    enabled            = optional(bool, true)
    window_minutes     = optional(number, 60)
    fingerprint_fields = optional(list(string), ["AlertName", "severity", "ResourceId"])
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

variable "audit_log" {
  description = "Audit log config (DDB-backed). Records every dispatched event + outcome per channel."
  type = object({
    enabled        = optional(bool, true)
    retention_days = optional(number, 365)
  })
  default = {}
}
