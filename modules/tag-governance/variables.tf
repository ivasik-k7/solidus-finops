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

variable "events_topic_arn" {
  description = "SNS topic ARN for tag-compliance + tag-drift + untagged-cost alerts. Required."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Encrypts the Config delivery bucket, the untagged-cost report Lambda's log group + env vars, and the events bus."
  type        = string
}

variable "required_tags" {
  description = "Tags that must be present on resources. The module chunks these into groups of 6 (AWS REQUIRED_TAGS rule limit) and creates one Config rule per chunk — no silent truncation."
  type = list(object({
    key            = string
    allowed_values = list(string)
  }))
}

variable "resource_types" {
  description = "AWS::Service::Resource type strings that the required-tags Config rule evaluates."
  type        = list(string)
}

variable "default_tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
}

# ---------------------------------------------------------------------------
# Observability + Lambda runtime
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for the untagged-cost report Lambda. Validated to >= 365 (Checkov CKV_AWS_338)."
  type        = number

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the untagged-cost report Lambda."
  type        = string
  default     = "python3.12"
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the untagged-cost report Lambda."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the untagged-cost report Lambda. Null = no reservation."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Config recorder
# ---------------------------------------------------------------------------

variable "record_global_resources" {
  description = "If true, the Config recorder includes global resource types (IAM, CloudFront, Route53). Set false to cut Config CI volume when you don't need to govern globals."
  type        = bool
  default     = true
}

variable "enable_config_recorder" {
  description = "Set to false if AWS Config is already enabled in this account at the org level."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Tag taxonomy + drift detection
# ---------------------------------------------------------------------------

variable "tag_taxonomy" {
  description = <<-EOT
    Optional rich metadata for each tag key the practice cares about. The
    untagged-cost report and the README documentation read this; the Config
    rule itself is still driven by `required_tags`.
      - level: "mandatory" | "recommended" | "operational"
      - purpose: "allocation" | "compliance" | "operational" | "lifecycle"
  EOT
  type = map(object({
    level       = string
    purpose     = string
    description = string
    examples    = optional(list(string), [])
  }))
  default = {}
}

variable "enable_tag_drift_detection" {
  description = "If true, mutations of allocation-critical tags emit an audit event to the events bus."
  type        = bool
  default     = true
}

variable "tag_drift_watched_keys" {
  description = "Tag keys whose creation, modification, or deletion trigger a drift audit event. Empty list disables the watch."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

# ---------------------------------------------------------------------------
# Untagged-cost report Lambda
# ---------------------------------------------------------------------------

variable "enable_untagged_cost_report" {
  description = "Deploy a weekly Lambda that dollarizes the tag gap. Requires Athena workgroup + CUR table + at least one mandatory tag."
  type        = bool
  default     = false
}

variable "untagged_cost_report_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the untagged-cost report."
  type        = string
  default     = "0 8 ? * MON *"
}

variable "untagged_cost_alarm_threshold_usd" {
  description = "Alarm if the total mandatory-tag-gap cost exceeds this value (current month). Null = skip alarm."
  type        = number
  default     = 1000
}

variable "untagged_cost_top_n" {
  description = "Number of top-cost untagged resources to surface in each weekly report."
  type        = number
  default     = 20
}

variable "athena_workgroup_name" {
  description = "Athena workgroup for the untagged-cost report (only consulted if enable_untagged_cost_report = true)."
  type        = string
  default     = null
}

variable "athena_database_name" {
  description = "Glue database holding the CUR table (only consulted if enable_untagged_cost_report = true)."
  type        = string
  default     = null
}

variable "cur_table_name" {
  description = "Glue table name for CUR 2.0."
  type        = string
  default     = "cur2"
}

# ---------------------------------------------------------------------------
# Allocation Resource Groups
# ---------------------------------------------------------------------------

variable "allocation_resource_groups" {
  description = <<-EOT
    Map of resource-group name -> { tag_key, tag_values } to provision as
    aws_resourcegroups_group. Lets the console filter by allocation
    dimension out-of-the-box.

    Example:
      allocation_resource_groups = {
        bu-retail-banking = { tag_key = "BusinessUnit", tag_values = ["retail-banking"] }
        cc-1234           = { tag_key = "CostCenter",   tag_values = ["CC-1234"] }
      }
  EOT
  type = map(object({
    tag_key    = string
    tag_values = list(string)
  }))
  default = {}
}
