###############################################################################
# Variables — input contract
#
# Grouped by purpose. Every variable has a description; required variables have
# no default; common operational knobs default to sensible production values.
###############################################################################

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix applied to every resource name (DDB table, Lambda functions, IAM roles, SQS queues, alarms, dashboard). Recommend: <namespace>-<environment>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.name_prefix))
    error_message = "name_prefix must be 2-63 chars, lowercase letters, digits, and hyphens; must start with a letter or digit."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN. Used to encrypt the DDB table, Lambda environment variables, and CloudWatch log groups. Required."
  type        = string
}

variable "schedules" {
  description = <<-EOT
    Named schedules. Each entry:
      days     = list of day codes ("MON","TUE","WED","THU","FRI","SAT","SUN"); empty list = always stopped
      start    = "HH:MM" 24h — resource must be RUNNING at and after this time on listed days
      stop     = "HH:MM" 24h — resource must be STOPPED at and after this time on listed days
      timezone = optional IANA timezone, default "UTC". Invalid values fall back to UTC with a warning.

    Edge cases:
      - days = []                        → resource is always stopped
      - start == stop                    → zero-duration running window; effectively always stopped
      - stop < start (e.g. 22:00→06:00)  → running window WRAPS over midnight
      - Invalid timezone string           → falls back to UTC (Lambda logs a warning)

    Example:
      schedules = {
        office-hours-cet = {
          days     = ["MON","TUE","WED","THU","FRI"]
          start    = "08:00"
          stop     = "18:00"
          timezone = "Europe/Berlin"
        }
        always-off = {
          days  = []
          start = "00:00"
          stop  = "00:00"
        }
        overnight-batch = {
          days     = ["MON","TUE","WED","THU","FRI"]
          start    = "22:00"   # runs through midnight
          stop     = "06:00"
          timezone = "UTC"
        }
      }
  EOT
  type = map(object({
    days     = list(string)
    start    = string
    stop     = string
    timezone = optional(string, "UTC")
  }))

  validation {
    condition = alltrue([
      for k, v in var.schedules :
      alltrue([for d in v.days : contains(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], upper(d))])
    ])
    error_message = "schedules.*.days must be three-letter codes: MON, TUE, WED, THU, FRI, SAT, SUN."
  }

  validation {
    condition = alltrue([
      for k, v in var.schedules :
      can(regex("^([01]\\d|2[0-3]):[0-5]\\d$", v.start)) && can(regex("^([01]\\d|2[0-3]):[0-5]\\d$", v.stop))
    ])
    error_message = "schedules.*.start and .stop must be HH:MM (24h)."
  }
}

# ---------------------------------------------------------------------------
# Optional integrations
# ---------------------------------------------------------------------------

variable "events_topic_arn" {
  description = "Optional SNS topic ARN for activity digests + alarm notifications. Null = no SNS publishing (metrics + DDB audit + alarms still work; alarm_actions are simply omitted)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the scheduler + discovery Lambdas. Valid CloudWatch retention values only."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}

variable "lambda_runtime" {
  description = "Python runtime for the scheduler + discovery Lambdas. Default tracks AWS-supported managed runtimes; update as runtimes are deprecated."
  type        = string
  default     = "python3.12"

  validation {
    condition     = can(regex("^python3\\.(1[0-9]|2[0-9])$", var.lambda_runtime))
    error_message = "lambda_runtime must be a Python 3.10+ runtime string (e.g. python3.12)."
  }
}

variable "default_tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Tag conventions
# ---------------------------------------------------------------------------

variable "opt_in_tag_key" {
  description = "Tag key that opts a resource INTO scheduling. The tag VALUE must match a key in `schedules`."
  type        = string
  default     = "Schedule"
}

variable "exception_tag_key" {
  description = "Tag key (any value) that excludes a resource from scheduling permanently."
  type        = string
  default     = "FinOpsException"
}

variable "override_until_tag_key" {
  description = "Tag key holding an ISO-8601 UTC timestamp. While now < timestamp, the scheduler skips this resource."
  type        = string
  default     = "ScheduleOverrideUntil"
}

# ---------------------------------------------------------------------------
# Resource-type toggles
# ---------------------------------------------------------------------------

variable "enable_ec2" {
  description = "Schedule EC2 instances. Spot instances are skipped automatically (they can't be stopped via API)."
  type        = bool
  default     = true
}

variable "enable_rds_instances" {
  description = "Schedule RDS DB instances. Read replicas attached to a primary are skipped automatically."
  type        = bool
  default     = true
}

variable "enable_rds_clusters" {
  description = "Schedule RDS DB clusters (Aurora). Engine modes that don't support start/stop (Aurora Serverless v1) are skipped automatically."
  type        = bool
  default     = true
}

variable "enable_asg" {
  description = "Schedule Auto Scaling Groups via scale-to-zero. ASG capacity is stashed in FinOpsSavedMin / FinOpsSavedDesired tags before stop and restored on start. Opt-in: scale-to-zero is intrusive."
  type        = bool
  default     = false
}

variable "enable_spot_management" {
  description = "Manage EC2 Spot instances. Spot stop semantics differ from on-demand (instance-store-backed AMIs cannot be stopped, EBS-backed stops break the spot contract). By default spot instances tagged for scheduling are skipped with an ActionSkippedSpot metric. Set true only after reviewing the implications."
  type        = bool
  default     = false
}

variable "dry_run" {
  description = "Preview mode. When true, the scheduler evaluates every resource and logs the action it WOULD take, but performs no AWS mutations. DDB STATE rows are written with outcome=dry-run, ACTION rows record action_type=dry-run-<would-be-action>, and a separate ActionDryRun metric is emitted. Useful for pre-deployment validation and 'what would happen at 18:00 CET tonight?' inquiries."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Multi-region + scheduling
# ---------------------------------------------------------------------------

variable "scan_regions" {
  description = "Regions to scan. Empty = home region only. Per-region failures are isolated — a bad region doesn't fail the whole tick."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.scan_regions : can(regex("^[a-z]{2}-[a-z]+-\\d$", r))])
    error_message = "Every scan_regions entry must be a valid AWS region code (e.g. eu-central-1)."
  }
}

variable "tick_schedule" {
  description = "EventBridge schedule expression for the scheduler Lambda. Standard `rate(...)` or `cron(...)` syntax. Shorter ticks = faster reaction + more Lambda invocations."
  type        = string
  default     = "rate(5 minutes)"
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------
#
# We deliberately do NOT estimate dollar values inside this module. Hourly
# rates differ by region, change over time, and ignore RIs / SPs / EDP —
# any hardcoded table is wrong on day one. Cost reporting is owned by the
# user's analytics tool (e.g. Cloudability) which reads CUR and reflects
# actual paid prices. The DDB ACTION rows hold every input the analytics
# layer needs: resource ID, type, region, account, action, timestamp.
#
# What the module DOES need is a blast-radius cap: if a misconfiguration
# (mass mis-tag, schedule typo) suddenly marks 5000 resources for stop,
# we want to act on at most N before pausing. That's count-based and
# never wrong.

variable "max_actions_per_tick" {
  description = "Maximum number of mutating actions (start + stop combined) the scheduler will perform in a single tick. Caps blast radius if detection misfires. Excess resources are recorded as ActionSkippedCeiling and re-evaluated next tick. Defaults to 200 — enough to handle a large account at 5-min ticks; small enough that a mass mis-tag can't take down a fleet in one invocation."
  type        = number
  default     = 200

  validation {
    condition     = var.max_actions_per_tick > 0
    error_message = "max_actions_per_tick must be > 0."
  }
}

# ---------------------------------------------------------------------------
# Auto-discovery
# ---------------------------------------------------------------------------

variable "enable_discovery" {
  description = "Deploy the weekly auto-discovery Lambda that scans CloudWatch for low-utilization resources lacking the opt-in tag and proposes scheduling candidates."
  type        = bool
  default     = true
}

variable "discovery_schedule_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the auto-discovery Lambda."
  type        = string
  default     = "0 9 ? * SUN *"
}

variable "discovery_cpu_threshold_pct" {
  description = "Average EC2 CPU % below this over discovery_lookback_days flags the resource as a candidate."
  type        = number
  default     = 5

  validation {
    condition     = var.discovery_cpu_threshold_pct > 0 && var.discovery_cpu_threshold_pct < 100
    error_message = "discovery_cpu_threshold_pct must be > 0 and < 100."
  }
}

variable "discovery_lookback_days" {
  description = "CloudWatch lookback window in days for auto-discovery CPU + DB-connection queries."
  type        = number
  default     = 14

  validation {
    condition     = var.discovery_lookback_days >= 1 && var.discovery_lookback_days <= 90
    error_message = "discovery_lookback_days must be 1-90."
  }
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

variable "state_ttl_days" {
  description = "DynamoDB STATE row TTL after last sighting. STATE rows hold the current-state-per-resource; expired rows are auto-cleaned."
  type        = number
  default     = 90
}

variable "action_ttl_days" {
  description = "DynamoDB ACTION row TTL — the audit trail. Default 2557 (7y) for SOX/PCI-friendly retention."
  type        = number
  default     = 2557
}
