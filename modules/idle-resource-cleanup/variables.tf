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
  description = "SNS topic ARN for digests + alarm actions. Required."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Encrypts DDB findings table, every Lambda's log group + env vars."
  type        = string
}

variable "default_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}

variable "lambda_runtime" {
  description = "Python runtime for every idle-cleanup Lambda."
  type        = string
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for every idle-cleanup Lambda. Validated to >= 365 (Checkov CKV_AWS_338)."
  type        = number

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on every idle-cleanup Lambda (ebs / eip / snapshot / nat / eni / lb)."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions per idle-cleanup Lambda. Null = no reservation."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Safety knobs
# ---------------------------------------------------------------------------

variable "dry_run" {
  description = "When true (default), every cleanup Lambda only reports. When false, mutation-capable scans actually delete (still bounded by cost ceiling + exception tags)."
  type        = bool
  default     = true
}

variable "exception_tag_key" {
  description = "Tag key that excludes a resource from cleanup. Default 'FinOpsException'."
  type        = string
  default     = "FinOpsException"
}

variable "cost_ceiling_usd" {
  description = "Maximum monthly USD value of resources any single Lambda will act on per invocation. Caps blast radius if detection misfires."
  type        = number
  default     = 10000
}

# ---------------------------------------------------------------------------
# Per-resource-type toggles
# ---------------------------------------------------------------------------

variable "enable_ebs_cleanup" {
  description = "Deploy the EBS idle-volume cleanup Lambda."
  type        = bool
  default     = true
}
variable "enable_eip_cleanup" {
  description = "Deploy the unassociated-EIP cleanup Lambda."
  type        = bool
  default     = true
}
variable "enable_snapshot_cleanup" {
  description = "Deploy the orphaned-snapshot cleanup Lambda."
  type        = bool
  default     = true
}
variable "enable_nat_cleanup" {
  description = "Deploy the idle-NAT-gateway cleanup Lambda."
  type        = bool
  default     = true
}
variable "enable_eni_cleanup" {
  description = "Deploy the leaked-ENI cleanup Lambda."
  type        = bool
  default     = true
}
variable "enable_lb_cleanup" {
  description = "Deploy the idle-load-balancer cleanup Lambda."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Per-resource-type age / threshold knobs
# ---------------------------------------------------------------------------

variable "ebs_min_age_days" {
  description = "Minimum age (days) before an unattached EBS volume is flagged."
  type        = number
}

variable "snapshot_min_age_days" {
  description = "Minimum age (days) before an EBS snapshot with no associated AMI is flagged."
  type        = number
}

variable "nat_min_age_days" {
  description = "Minimum age (days) before a NAT gateway is flagged."
  type        = number
  default     = 14
}
variable "nat_idle_lookback_days" {
  description = "Days of CloudWatch metrics to inspect when judging NAT idleness."
  type        = number
  default     = 7
}
variable "nat_idle_bytes_threshold" {
  description = "BytesOutToDestination/day below which a NAT is considered idle. Default 1 MiB."
  type        = number
  default     = 1048576
}
variable "eni_min_age_days" {
  description = "Minimum age (days) before an unattached ENI is flagged."
  type        = number
  default     = 7
}
variable "lb_min_age_days" {
  description = "Minimum age (days) before an ALB/NLB is flagged."
  type        = number
  default     = 14
}
variable "lb_idle_lookback_days" {
  description = "Days of CloudWatch metrics to inspect when judging LB idleness."
  type        = number
  default     = 7
}
variable "lb_idle_request_threshold" {
  description = "Requests/lookback-window below which an LB is considered idle. Default 100."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# EBS phase-2 grace
# ---------------------------------------------------------------------------

variable "ebs_pending_grace_hours" {
  description = "Hours a volume must stay in 'FinOpsPendingDeletion=<snap>' state before phase-2 deletion finalizes."
  type        = number
  default     = 24
}

variable "ebs_pending_grace_max_hours" {
  description = "Hours after which a pending-deletion volume rolls back (tags cleared, error surfaced)."
  type        = number
  default     = 168 # 7 days
}

# ---------------------------------------------------------------------------
# Per-resource schedules
# ---------------------------------------------------------------------------

variable "ebs_schedule" {
  description = "EventBridge schedule for the EBS cleanup Lambda."
  type        = string
  default     = "cron(0 9 ? * MON *)"
}
variable "snapshot_schedule" {
  description = "EventBridge schedule for the snapshot cleanup Lambda."
  type        = string
  default     = "cron(0 10 ? * MON *)"
}
variable "nat_schedule" {
  description = "EventBridge schedule for the NAT cleanup Lambda."
  type        = string
  default     = "cron(0 11 ? * MON *)"
}
variable "lb_schedule" {
  description = "EventBridge schedule for the LB cleanup Lambda."
  type        = string
  default     = "cron(0 12 ? * MON *)"
}
variable "eip_schedule" {
  description = "EventBridge schedule for the EIP cleanup Lambda."
  type        = string
  default     = "cron(0 13 ? * MON *)"
}
variable "eni_schedule" {
  description = "EventBridge schedule for the ENI cleanup Lambda."
  type        = string
  default     = "cron(0 14 ? * MON *)"
}

# ---------------------------------------------------------------------------
# Multi-region + state tracking
# ---------------------------------------------------------------------------

variable "scan_regions" {
  description = "Regions to scan for idle resources. Each Lambda iterates these in turn and uses regional boto3 clients. Empty list = the Lambda's home region only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.scan_regions : can(regex("^[a-z]{2}-[a-z]+-\\d$", r))])
    error_message = "Every scan_regions entry must be a valid AWS region code (e.g. eu-central-1)."
  }
}

variable "aging_seen_count_threshold" {
  description = "Number of consecutive scans the same resource must appear in before its severity is bumped to high — signals an ignored finding."
  type        = number
  default     = 10
}

variable "findings_ttl_days" {
  description = "Days a STATE row is retained in DynamoDB after it stops appearing in scans."
  type        = number
  default     = 90
}

variable "actions_ttl_days" {
  description = "Days an ACTION row (deletion / release / snapshot) is retained. Default 7 years for audit-grade trail."
  type        = number
  default     = 2557
}

# ---------------------------------------------------------------------------
# Aggregate alarm
# ---------------------------------------------------------------------------

variable "total_waste_alarm_threshold_usd" {
  description = "Alarm if combined MonthlyWasteUsd across all resource types exceeds this value. Null disables the alarm."
  type        = number
  default     = 500
}
