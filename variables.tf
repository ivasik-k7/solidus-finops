###############################################################################
# FinOps framework — root input contract
#
# Naming convention (strict): every variable that configures a specific
# submodule is prefixed with that submodule's slug, e.g. cost_data_exports_*,
# instance_scheduler_*, tag_governance_*. Only truly cross-cutting concerns
# (namespace, environment, KMS, log retention, Lambda runtime, region) are
# un-prefixed.
#
# Boolean toggles use the suffix form `<module>_enabled = true|false`
# (NOT the legacy `enable_<module>`). This keeps every module's settings
# grouped together when the variables.tf is alphabetised or sorted.
#
# Sections, in deployment order:
#   1. Identity & naming
#   2. Tagging defaults
#   3. Encryption
#   4. Observability (log retention, Lambda runtime)
#   5. Alerting (the events bus — first to deploy)
#   6. Cost data exports
#   7. Tag governance
#   8. Budgets
#   9. Idle resource cleanup
#  10. Instance scheduler
#  11. FinOps metrics
###############################################################################

###############################################################################
# 1. Identity & naming — cross-cutting, no module prefix
###############################################################################

variable "namespace" {
  description = "Short identifier for the org/account, used in resource naming. Lowercase letters, digits, hyphens; 2-32 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,32}$", var.namespace))
    error_message = "namespace must be 2-32 chars, lowercase letters, digits, and hyphens only."
  }
}

variable "environment" {
  description = "Environment in which the FinOps stack itself runs (e.g. 'shared', 'platform', 'prod')."
  type        = string
  default     = "shared"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.environment))
    error_message = "environment must be 1-16 chars, lowercase letters, digits, and hyphens only."
  }
}

variable "stack_name" {
  description = "Stack identity used in the naming prefix. Defaults to 'finops'. Override to vendor the framework, run multiple FinOps stacks side-by-side, or re-brand internally."
  type        = string
  default     = "finops"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,24}$", var.stack_name))
    error_message = "stack_name must be 2-24 chars, lowercase letters, digits, and hyphens only."
  }
}

variable "aws_primary_region" {
  description = "Home region for the FinOps stack. KMS key, DynamoDB tables, Lambdas, alarms, dashboards, and the events SNS topic are all created here. CUR is always created in us-east-1 via a separate provider alias regardless of this value."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_primary_region))
    error_message = "aws_primary_region must be a valid AWS region code (e.g. eu-central-1, us-east-1)."
  }
}

variable "aws_secondary_regions" {
  description = <<-EOT
    Additional regions where scanning modules (idle-resource-cleanup,
    instance-scheduler) iterate to find resources. Framework infrastructure
    itself stays in aws_primary_region.

    The framework computes `effective_regions = [primary] + secondaries` and
    uses it as the default for any per-module *_scan_regions variable that
    is left empty. Per-module scan_regions, when non-empty, override this
    default for that module only.

    Example:
      aws_primary_region    = "eu-central-1"
      aws_secondary_regions = ["us-east-1", "ap-southeast-1"]

      # idle-cleanup + instance-scheduler scan all 3 regions by default.
      # To scan only one region for one module, override:
      # idle_cleanup_scan_regions = ["eu-central-1"]
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.aws_secondary_regions : can(regex("^[a-z]{2}-[a-z]+-\\d$", r))])
    error_message = "Every entry in aws_secondary_regions must be a valid AWS region code (e.g. us-east-1, ap-southeast-1)."
  }
}

###############################################################################
# 2. Tagging defaults
###############################################################################

variable "extra_tags" {
  description = "Caller-supplied tags merged into the framework default_tags. Keys here override framework defaults."
  type        = map(string)
  default     = {}
}

###############################################################################
# 3. Encryption
###############################################################################

variable "create_kms_key" {
  description = "Create a dedicated KMS CMK for FinOps data encryption. Set false to bring your own via existing_kms_key_arn."
  type        = bool
  default     = true
}

variable "existing_kms_key_arn" {
  description = "Existing KMS key ARN to use when create_kms_key is false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_kms_key_arn == null || can(regex("^arn:aws[a-z0-9-]*:kms:[a-z0-9-]+:\\d{12}:key/[a-f0-9-]+$", var.existing_kms_key_arn))
    error_message = "existing_kms_key_arn must be a valid KMS key ARN or null."
  }
}

variable "kms_key_deletion_window_days" {
  description = "KMS CMK deletion window (days). AWS allows 7-30; banks typically pin to 30."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

###############################################################################
# 4. Observability — shared across every Lambda the framework deploys
###############################################################################

variable "log_retention_days" {
  description = "CloudWatch log retention for all FinOps Lambda log groups. Default 365 (1y) suits most accounts. Set to 2557 (7y) for SOX/PCI/GDPR-regulated workloads, or 1827 (5y) for DORA."
  type        = number
  default     = 365

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch retention value (0,1,3,5,7,14,30,60,90,120,150,180,365,400,545,731,1096,1827,2192,2557,2922,3288,3653)."
  }
}

variable "lambda_runtime" {
  description = "Python runtime applied to every Lambda the framework deploys. Bump in lockstep with AWS Lambda runtime deprecation announcements."
  type        = string
  default     = "python3.12"

  validation {
    condition     = can(regex("^python3\\.(1[0-9]|2[0-9])$", var.lambda_runtime))
    error_message = "lambda_runtime must be a supported Python runtime (python3.10 .. python3.29)."
  }
}

###############################################################################
# 5. Alerting — the events bus + multi-channel dispatcher.
#
# Deploys unconditionally; this is the spine every other module publishes to.
# Channels are opt-in: with no channels configured the dispatcher is a no-op
# and downstream modules still emit metrics + DDB audit rows.
###############################################################################

variable "alerting_channels" {
  description = <<-EOT
    Multi-channel destination configuration for the alerting module. Each
    channel type holds 0+ destinations, each with a min_severity filter
    (info / low / medium / high / critical).

    Leave empty to use the legacy alerting_legacy_emails / alerting_slack_webhook_url /
    alerting_teams_webhook_url variables. See modules/alerting/README.md for the full
    schema (PagerDuty, Opsgenie, generic webhooks, SQS).
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
}

variable "alerting_deduplication" {
  description = "Deduplication settings for the alerting dispatcher."
  type = object({
    enabled            = optional(bool, true)
    window_minutes     = optional(number, 60)
    fingerprint_fields = optional(list(string), ["AlertName", "severity", "ResourceId"])
  })
  default = {}
}

variable "alerting_audit_log" {
  description = "Audit log settings for the alerting dispatcher."
  type = object({
    enabled        = optional(bool, true)
    retention_days = optional(number, 365)
  })
  default = {}
}

variable "alerting_legacy_emails" {
  description = "Legacy: SNS email subscribers. Prefer alerting_channels.email for fine-grained control. Wired through only when alerting_channels is empty."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.alerting_legacy_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))
    ])
    error_message = "alerting_legacy_emails must contain valid email addresses."
  }
}

variable "alerting_slack_webhook_url" {
  description = "Slack incoming webhook URL (legacy single-channel input). Null disables the Slack notifier. SENSITIVE — set as a sensitive variable in TFE, never commit. Prefer alerting_channels.slack."
  type        = string
  default     = null
  sensitive   = true
}

variable "alerting_teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL (legacy single-channel input). Null disables the Teams notifier. SENSITIVE. Prefer alerting_channels.teams."
  type        = string
  default     = null
  sensitive   = true
}

###############################################################################
# 6. Cost data exports — CUR 2.0, optional FOCUS, optional Athena + queries.
###############################################################################

variable "cost_data_exports_enabled" {
  description = "Provision the cost-data-exports module (CUR 2.0 export, S3 bucket, optionally FOCUS + Athena)."
  type        = bool
  default     = true
}

variable "cost_data_exports_focus_enabled" {
  description = "Emit FOCUS 1.0 export alongside CUR. Recommended for multi-cloud reporting or future-proofing."
  type        = bool
  default     = true
}

variable "cost_data_exports_athena_enabled" {
  description = "Provision an Athena workgroup, Glue database, and KMS-encrypted results bucket for CUR/FOCUS querying."
  type        = bool
  default     = true
}

variable "cost_data_exports_bucket_name" {
  description = "Override the S3 bucket name for cost-data exports. If null, derived as <name_prefix>-cost-data-<account_id>."
  type        = string
  default     = null
}

variable "cost_data_exports_retention_days" {
  description = "Days to keep current CUR/FOCUS objects in S3 Standard before tiering to Glacier Instant Retrieval (still Athena-queryable). 0 disables tiering."
  type        = number
  default     = 90

  validation {
    condition     = var.cost_data_exports_retention_days >= 0
    error_message = "cost_data_exports_retention_days must be >= 0."
  }
}

variable "cost_data_exports_expiration_days" {
  description = "Total retention (days) for current cost-data objects before they expire. Banks: 2555 (7 years) for SOX/PCI. Must be >= cost_data_exports_retention_days."
  type        = number
  default     = 2555

  validation {
    condition     = var.cost_data_exports_expiration_days >= 1
    error_message = "cost_data_exports_expiration_days must be >= 1."
  }
}

variable "cost_data_exports_cross_account_readers" {
  description = <<-EOT
    Cross-account IAM roles for 3rd-party FinOps tools (Cloudability, CloudHealth,
    Vantage, Apptio, ...) to assume and read the CUR bucket.

    Example for Cloudability:
      cost_data_exports_cross_account_readers = [{
        name          = "cloudability"
        account_id    = "165761016623"          # Cloudability's account
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
}

variable "cost_data_exports_health_check_enabled" {
  description = "Deploy the daily health-check Lambda for the cost-data pipeline (CUR freshness + crawler success + Athena queryability)."
  type        = bool
  default     = true
}

variable "cost_data_exports_health_check_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the cost-data health check."
  type        = string
  default     = "0 9 * * ? *"
}

variable "cost_data_exports_cur_freshness_alarm_hours" {
  description = "Alarm if the newest CUR delivery is older than this many hours. Null disables."
  type        = number
  default     = 36
}

variable "cost_data_exports_named_queries_enabled" {
  description = "Register the pre-built FinOps Athena named-queries library in the workgroup."
  type        = bool
  default     = true
}

variable "cost_data_exports_extra_named_queries" {
  description = "Additional Athena named queries to register alongside the built-in library."
  type = map(object({
    description = string
    query       = string
  }))
  default = {}
}

###############################################################################
# 7. Tag governance — Config rules, taxonomy, drift detection, untagged-cost
###############################################################################

variable "tag_governance_enabled" {
  description = "Deploy the tag-governance module (Config rules + tag drift detection + optional untagged-cost report + Allocation Resource Groups). Set false to skip entirely."
  type        = bool
  default     = true
}

variable "tag_governance_required_tags" {
  description = <<-EOT
    Tags that must be present on resources. Each entry:
      { key = string, allowed_values = list(string) }
    The tag-governance module chunks these into groups of 6 (AWS REQUIRED_TAGS
    rule limit) and creates one Config rule per chunk — no silent truncation.
  EOT
  type = list(object({
    key            = string
    allowed_values = list(string)
  }))
  default = [
    { key = "CostCenter", allowed_values = [] },
    { key = "Environment", allowed_values = ["prod", "nonprod", "dr", "sandbox"] },
    { key = "Application", allowed_values = [] },
    { key = "Owner", allowed_values = [] },
    { key = "BusinessUnit", allowed_values = [] },
    { key = "DataClassification", allowed_values = ["public", "internal", "confidential", "restricted"] },
  ]

  validation {
    condition = alltrue([
      for t in var.tag_governance_required_tags : can(regex("^[a-zA-Z0-9 +\\-=._:/@]{1,128}$", t.key))
    ])
    error_message = "tag_governance_required_tags keys must be valid AWS tag keys (1-128 chars: letters, digits, spaces, and + - = . _ : / @)."
  }
}

variable "tag_governance_record_global_resources" {
  description = "If true, the Config recorder includes global resource types (IAM, CloudFront, Route53). Set false to cut CI volume when you don't need to govern globals."
  type        = bool
  default     = true
}

variable "tag_governance_taxonomy" {
  description = <<-EOT
    Rich metadata per tag key (optional). When supplied, drives the
    untagged-cost report's mandatory list (level = "mandatory" entries) and
    is rendered in the module's documentation outputs. The Config rule is
    still driven by tag_governance_required_tags.
  EOT
  type = map(object({
    level       = string
    purpose     = string
    description = string
    examples    = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.tag_governance_taxonomy :
      contains(["mandatory", "recommended", "operational"], v.level)
    ])
    error_message = "tag_governance_taxonomy[*].level must be one of: mandatory, recommended, operational."
  }

  validation {
    condition = alltrue([
      for k, v in var.tag_governance_taxonomy :
      contains(["allocation", "compliance", "operational", "lifecycle"], v.purpose)
    ])
    error_message = "tag_governance_taxonomy[*].purpose must be one of: allocation, compliance, operational, lifecycle."
  }
}

variable "tag_governance_drift_detection_enabled" {
  description = "Audit mutations of allocation-critical tag keys to the events bus."
  type        = bool
  default     = true
}

variable "tag_governance_drift_watched_keys" {
  description = "Tag keys whose mutations emit an audit event. Default covers the standard FinOps allocation set."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

variable "tag_governance_untagged_cost_report_enabled" {
  description = "Deploy a weekly Lambda that dollarizes the tag gap. Requires cost_data_exports_enabled + cost_data_exports_athena_enabled."
  type        = bool
  default     = false
}

variable "tag_governance_untagged_cost_report_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the untagged-cost report."
  type        = string
  default     = "0 8 ? * MON *"
}

variable "tag_governance_untagged_cost_alarm_threshold_usd" {
  description = "Alarm if the total monthly untagged-cost gap exceeds this value. Null disables the alarm."
  type        = number
  default     = 1000
}

variable "tag_governance_allocation_resource_groups" {
  description = <<-EOT
    Map of resource-group key → { tag_key, tag_values } to provision as
    aws_resourcegroups_group resources. Lets the AWS Console filter by
    allocation dimension instantly.
  EOT
  type = map(object({
    tag_key    = string
    tag_values = list(string)
  }))
  default = {}
}

variable "tag_governance_compliance_resource_types" {
  description = "AWS::Service::Resource type strings that the required-tags Config rule evaluates."
  type        = list(string)
  default = [
    "AWS::EC2::Instance",
    "AWS::EC2::Volume",
    "AWS::S3::Bucket",
    "AWS::RDS::DBInstance",
    "AWS::Lambda::Function",
    "AWS::ECS::Service",
    "AWS::EKS::Cluster",
    "AWS::DynamoDB::Table",
    "AWS::ElasticLoadBalancingV2::LoadBalancer",
  ]
}

###############################################################################
# 8. Budgets — polymorphic map of budget definitions + performance tracking
###############################################################################

variable "budgets_currency" {
  description = "ISO 4217 currency code applied to all budgets (e.g. USD, EUR, GBP)."
  type        = string
  default     = "USD"

  validation {
    condition     = can(regex("^[A-Z]{3}$", var.budgets_currency))
    error_message = "budgets_currency must be a 3-letter ISO 4217 code (uppercase)."
  }
}

variable "budgets_default_thresholds" {
  description = "Threshold ladder applied to any budget that doesn't specify its own (passed through to the budgets module)."
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

variable "budgets_performance_tracking_enabled" {
  description = "Deploy the daily budget-performance Lambda (variance, burn-rate, adherence score, anomaly correlation, dashboard)."
  type        = bool
  default     = true
}

variable "budgets_performance_schedule_cron" {
  description = "EventBridge cron (UTC, six fields) for the budget-performance Lambda."
  type        = string
  default     = "0 7 * * ? *"
}

variable "budgets_adherence_alarm_threshold" {
  description = "Alarm if BudgetAdherenceScore (% of budgets within target) drops below this. Null disables."
  type        = number
  default     = 80
}

variable "budgets_burn_rate_alarm_days_to_breach" {
  description = "Alarm if any single budget's BurnRateDaysToBreach metric drops below this. Null disables. (Applied as a metric-math alarm on the lowest of all per-budget series.)"
  type        = number
  default     = 7
}

variable "budgets_items" {
  description = <<-EOT
    Polymorphic budget definitions, keyed by stable identifier.

    Required per entry:
      scope  = "account" | "service" | "tag" | "cost_category"
      amount = number   # limit, in budgets_currency unless overridden

    Optional period + currency overrides:
      time_unit = "MONTHLY" | "QUARTERLY" | "ANNUALLY"   (default MONTHLY)
      currency  = ISO 4217 code; overrides budgets_currency for this budget only

    Filter target (required for non-account scope):
      service:        { service        = "Amazon EC2 - Compute" }
      tag:            { tag_key        = "BusinessUnit", tag_value = "retail" }
      cost_category:  { category_name  = "BusinessUnit", category_value = "retail" }

    Custom thresholds (default ladder if omitted):
      thresholds = [ { pct = 80, type = "ACTUAL" }, ... ]

    Per-budget email subscribers (in addition to events bus):
      extra_notification_emails = [ "alice@example.com", ... ]

    AWS Budget Actions (auto-enforcement on breach):
      actions = [{
        threshold_pct     = 100
        action_type       = "APPLY_IAM_POLICY" | "APPLY_SCP_POLICY" | "RUN_SSM_DOCUMENTS"
        approval_model    = "MANUAL" | "AUTOMATIC"
        # APPLY_IAM_POLICY:
        iam_policy_arn  = arn
        iam_roles       = [...]
        iam_groups      = [...]
        iam_users       = [...]
        # APPLY_SCP_POLICY:
        scp_policy_id   = id
        scp_target_ids  = [...]
        # RUN_SSM_DOCUMENTS:
        ssm_action_subtype = "STOP_EC2_INSTANCES" | "STOP_RDS_INSTANCES"
        ssm_region         = "eu-central-1"
        ssm_instance_ids   = [...]
        subscribers        = [ "ops@example.com" ]
      }]

    Governance metadata:
      owner       = "team@example.com"
      approver    = "cfo@example.com"
      approved_at = "2026-01-15"
      purpose     = "FY26 retail-banking compute budget"
  EOT
  type = map(object({
    scope     = string
    amount    = number
    time_unit = optional(string, "MONTHLY")
    currency  = optional(string, null)
    target = optional(object({
      service        = optional(string)
      tag_key        = optional(string)
      tag_value      = optional(string)
      category_name  = optional(string)
      category_value = optional(string)
    }))
    thresholds = optional(list(object({
      pct  = number
      type = optional(string, "ACTUAL")
    })), [])
    extra_notification_emails = optional(list(string), [])
    actions = optional(list(object({
      threshold_pct      = number
      notification_type  = optional(string, "ACTUAL")
      action_type        = string
      approval_model     = optional(string, "MANUAL")
      iam_policy_arn     = optional(string)
      iam_roles          = optional(list(string), [])
      iam_groups         = optional(list(string), [])
      iam_users          = optional(list(string), [])
      scp_policy_id      = optional(string)
      scp_target_ids     = optional(list(string), [])
      ssm_action_subtype = optional(string)
      ssm_region         = optional(string)
      ssm_instance_ids   = optional(list(string), [])
      subscribers        = optional(list(string), [])
    })), [])
    owner       = optional(string, "(unowned)")
    approver    = optional(string, "")
    approved_at = optional(string, "")
    purpose     = optional(string, "")
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.budgets_items : contains(["account", "service", "tag", "cost_category"], v.scope)
    ])
    error_message = "Each budgets_items entry's scope must be one of: account, service, tag, cost_category."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets_items : contains(["MONTHLY", "QUARTERLY", "ANNUALLY"], v.time_unit)
    ])
    error_message = "Each budgets_items entry's time_unit must be one of: MONTHLY, QUARTERLY, ANNUALLY."
  }

  validation {
    condition     = alltrue([for k, v in var.budgets_items : v.amount > 0])
    error_message = "All budgets_items.*.amount must be > 0."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets_items : v.scope == "account" || v.target != null
    ])
    error_message = "Non-account budgets require a target."
  }

  # NOTE: each per-scope validation uses try() to read the nested attribute,
  # because Terraform's validation evaluator does NOT short-circuit `||`
  # before resolving attribute access on a null parent. Without try(),
  # `v.target.service` fails the entire validation for an "account"-scope
  # budget where target is intentionally null. try() returns the fallback
  # (false) on any access error, which the `v.scope != "X" ||` left-hand
  # side then bypasses for non-matching scopes.

  validation {
    condition = alltrue([
      for k, v in var.budgets_items :
      v.scope != "service" || try(v.target.service != null, false)
    ])
    error_message = "Scope 'service' budgets require target.service."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets_items :
      v.scope != "tag" || try(v.target.tag_key != null && v.target.tag_value != null, false)
    ])
    error_message = "Scope 'tag' budgets require target.tag_key and target.tag_value."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets_items :
      v.scope != "cost_category" || try(v.target.category_name != null && v.target.category_value != null, false)
    ])
    error_message = "Scope 'cost_category' budgets require target.category_name and target.category_value."
  }
}

###############################################################################
# 9. Idle resource cleanup — EBS / snapshot / EIP / ENI / NAT / LB
###############################################################################

variable "idle_cleanup_enabled" {
  description = "Deploy idle-resource-cleanup Lambdas (EBS / EIP / Snapshot). Default false — even with dry_run on, deploying mutation-capable Lambdas should be an explicit decision."
  type        = bool
  default     = false
}

variable "idle_cleanup_dry_run" {
  description = "When true, Lambdas only report; they do not delete or modify resources. Keep true until you have run a full reporting cycle and reviewed findings."
  type        = bool
  default     = true
}

variable "idle_cleanup_exception_tag_key" {
  description = "Tag key (any value) that excludes a resource from idle cleanup actions."
  type        = string
  default     = "FinOpsException"
}

variable "idle_cleanup_ebs_min_age_days" {
  description = "Minimum age (days) before an unattached EBS volume is flagged for cleanup."
  type        = number
  default     = 14

  validation {
    condition     = var.idle_cleanup_ebs_min_age_days >= 1
    error_message = "idle_cleanup_ebs_min_age_days must be >= 1."
  }
}

variable "idle_cleanup_snapshot_min_age_days" {
  description = "Minimum age (days) before an EBS snapshot with no associated AMI is flagged."
  type        = number
  default     = 90

  validation {
    condition     = var.idle_cleanup_snapshot_min_age_days >= 1
    error_message = "idle_cleanup_snapshot_min_age_days must be >= 1."
  }
}

variable "idle_cleanup_scan_regions" {
  description = "Regions the idle-resource-cleanup Lambdas iterate over. Empty list (default) = framework effective_regions ([aws_primary_region] + aws_secondary_regions). Set explicitly to scope this module to a different region list."
  type        = list(string)
  default     = []
}

variable "idle_cleanup_aging_seen_count_threshold" {
  description = "Number of consecutive scans a finding must persist before its severity is bumped to high (signals an ignored finding)."
  type        = number
  default     = 10
}

###############################################################################
# 10. Instance scheduler — tag-driven start/stop with action-count blast cap
###############################################################################

variable "instance_scheduler_enabled" {
  description = "Deploy the tag-driven instance scheduler. Default false — a Lambda with ec2:StopInstances should be an explicit decision."
  type        = bool
  default     = false
}

variable "instance_scheduler_opt_in_tag_key" {
  description = "Tag key that opts an instance INTO scheduling. Value is the schedule name (e.g. 'office-hours-cet')."
  type        = string
  default     = "Schedule"
}

variable "instance_scheduler_schedules" {
  description = <<-EOT
    Named schedules. Each schedule defines: which days of the week the
    resource should be running, at what start time, until what stop time,
    in which timezone.

      days     = list of day codes — "MON" "TUE" "WED" "THU" "FRI" "SAT" "SUN"
      start    = "HH:MM" 24h — resource must be RUNNING at and after this time on listed days
      stop     = "HH:MM" 24h — resource must be STOPPED at and after this time on listed days
      timezone = optional IANA timezone, default "UTC"

    Example:
      {
        office-hours-cet = {
          days     = ["MON", "TUE", "WED", "THU", "FRI"]
          start    = "08:00"
          stop     = "18:00"
          timezone = "Europe/Berlin"
        }
        always-off = {
          days  = []        # empty days list = always stopped
          start = "00:00"
          stop  = "00:00"
        }
      }
  EOT
  type = map(object({
    days     = list(string)
    start    = string
    stop     = string
    timezone = optional(string, "UTC")
  }))
  default = {
    office-hours-cet = {
      days     = ["MON", "TUE", "WED", "THU", "FRI"]
      start    = "08:00"
      stop     = "18:00"
      timezone = "Europe/Berlin"
    }
    office-hours-est = {
      days     = ["MON", "TUE", "WED", "THU", "FRI"]
      start    = "08:00"
      stop     = "18:00"
      timezone = "America/New_York"
    }
  }
}

variable "instance_scheduler_scan_regions" {
  description = "Regions the instance-scheduler iterates. Empty (default) = framework effective_regions ([aws_primary_region] + aws_secondary_regions). Set explicitly to scope this module to a different region list."
  type        = list(string)
  default     = []
}

variable "instance_scheduler_tick_schedule" {
  description = "EventBridge schedule expression for the scheduler Lambda tick."
  type        = string
  default     = "rate(5 minutes)"
}

variable "instance_scheduler_enable_rds_instances" {
  description = "Schedule RDS DB instances."
  type        = bool
  default     = true
}

variable "instance_scheduler_enable_rds_clusters" {
  description = "Schedule RDS DB clusters (Aurora)."
  type        = bool
  default     = true
}

variable "instance_scheduler_enable_asg" {
  description = "Schedule Auto Scaling Groups via scale-to-zero. Intrusive — opt-in deliberately."
  type        = bool
  default     = false
}

variable "instance_scheduler_max_actions_per_tick" {
  description = "Blast-radius cap: hard ceiling on mutating actions per tick. Caps damage if a misconfiguration mass-targets resources."
  type        = number
  default     = 200
}

variable "instance_scheduler_discovery_enabled" {
  description = "Deploy the weekly auto-discovery Lambda that proposes scheduling candidates."
  type        = bool
  default     = true
}

variable "instance_scheduler_discovery_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the auto-discovery Lambda."
  type        = string
  default     = "0 9 ? * SUN *"
}

###############################################################################
# 11. FinOps metrics — KPI aggregator (requires cost_data_exports + Athena)
###############################################################################

variable "finops_metrics_enabled" {
  description = "Deploy the finops-metrics module: Athena named queries + daily KPI aggregator → CloudWatch + SSM. Requires cost_data_exports_enabled + cost_data_exports_athena_enabled."
  type        = bool
  default     = true
}

variable "finops_metrics_allocation_tag_keys" {
  description = "Tag keys treated as 'allocation tags'. A CUR line counts as allocated only if it carries all of these. Typically [CostCenter, BusinessUnit, Application]."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

variable "finops_metrics_aggregator_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the KPI aggregator Lambda."
  type        = string
  default     = "0 7 * * ? *"
}

variable "finops_metrics_alarm_thresholds" {
  description = "Per-KPI absolute-threshold alarm thresholds. Set any value to null to skip that alarm."
  type = object({
    allocation_coverage_min_pct     = optional(number, 80)
    commitment_coverage_min_pct     = optional(number, 70)
    commitment_utilization_min_pct  = optional(number, 80)
    forecast_accuracy_max_drift_pct = optional(number, 15)
  })
  default = {}
}

variable "finops_metrics_builtin_kpis_enabled" {
  description = "Per-KPI on/off map. Set any key to false to skip that built-in KPI entirely (no metric, no DDB snapshot, no alarm). Useful when an external tool (e.g. Cloudability) already owns the value."
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

variable "finops_metrics_custom_kpis" {
  description = <<-EOT
    User-defined KPIs. Each entry is registered as an Athena named query AND
    executed by the aggregator Lambda, emitted as a CloudWatch metric
    (Custom_<key>), written to a DDB snapshot, and optionally alarmed on.

    The SQL must return a single row with a single numeric column. Available
    substitutions: $${cur} → full CUR table, $${db} → database, $${prefix} → name_prefix.

    Example:
      finops_metrics_custom_kpis = {
        cost_per_transaction = {
          description = "Account spend / daily transaction count"
          sql         = "SELECT ROUND(SUM(line_item_unblended_cost) / 100000.0, 4) FROM $${cur} WHERE billing_period = date_format(current_date, '%Y-%m')"
          unit        = "None"
          alarm       = { comparison = "GreaterThan", threshold = 0.50 }
        }
      }
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
}

variable "finops_metrics_trend_metrics_enabled" {
  description = "Emit derived trend metrics (<Metric>_7dAvg / _30dAvg / _WoWDriftPct) computed from the DDB snapshot history. Unlocks week-over-week drift alarms."
  type        = bool
  default     = true
}

variable "finops_metrics_wow_drift_alarm_threshold_pct" {
  description = "Alarm if AllocationCoveragePct drops > N% week-over-week. Null disables. Independent of the absolute-threshold alarms — catches regression that an absolute floor misses."
  type        = number
  default     = 5
}

variable "finops_metrics_snapshot_retention_days" {
  description = "Days to keep daily KPI snapshots in DDB. Drives moving-average + drift compute. Minimum 35; default 400 (year + slack)."
  type        = number
  default     = 400
}

variable "finops_metrics_tag_value_dashboard_tag" {
  description = "If set (e.g. \"BusinessUnit\"), the aggregator queries Athena for distinct values of this tag and rebuilds the dashboard with one widget per value. Null disables this feature."
  type        = string
  default     = null
}

variable "finops_metrics_tag_value_dashboard_top_n" {
  description = "Max number of tag values to render as dashboard widgets. 0..30."
  type        = number
  default     = 12
}
