###############################################################################
# Identity & naming
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

variable "aws_region" {
  description = "Primary AWS region for FinOps resources. CUR is always created in us-east-1 via a provider alias."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must be a valid AWS region code (e.g. eu-central-1, us-east-1)."
  }
}

###############################################################################
# Tagging
###############################################################################

variable "extra_tags" {
  description = "Caller-supplied tags merged into the framework default_tags. Keys here override framework defaults."
  type        = map(string)
  default     = {}
}

###############################################################################
# Encryption
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
# Cost & Usage data exports
###############################################################################

variable "enable_cost_data_exports" {
  description = "Provision the cost-data-exports module (CUR 2.0 export, S3 bucket, optionally FOCUS + Athena)."
  type        = bool
  default     = true
}

variable "enable_focus_export" {
  description = "Emit FOCUS 1.0 export alongside CUR. Recommended for multi-cloud reporting or future-proofing."
  type        = bool
  default     = true
}

variable "enable_athena_workgroup" {
  description = "Provision an Athena workgroup, Glue database, and KMS-encrypted results bucket for CUR/FOCUS querying."
  type        = bool
  default     = true
}

variable "cost_data_bucket_name" {
  description = "Override the S3 bucket name for cost-data exports. If null, derived as <name_prefix>-cost-data-<account_id>."
  type        = string
  default     = null
}

variable "cost_data_retention_days" {
  description = "Days to keep current CUR/FOCUS objects in S3 Standard before tiering to Glacier Instant Retrieval (still Athena-queryable). 0 disables tiering."
  type        = number
  default     = 90

  validation {
    condition     = var.cost_data_retention_days >= 0
    error_message = "cost_data_retention_days must be >= 0."
  }
}

variable "cost_data_expiration_days" {
  description = "Total retention (days) for current cost-data objects before they expire. Banks: 2555 (7 years) for SOX/PCI. Must be >= cost_data_retention_days."
  type        = number
  default     = 2555

  validation {
    condition     = var.cost_data_expiration_days >= 1
    error_message = "cost_data_expiration_days must be >= 1."
  }
}

###############################################################################
# Tag governance
###############################################################################

variable "required_tags" {
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
    # AWS tag keys: letters, digits, spaces, and + - = . _ : / @
    condition = alltrue([
      for t in var.required_tags : can(regex("^[a-zA-Z0-9 +\\-=._:/@]{1,128}$", t.key))
    ])
    error_message = "required_tags keys must be valid AWS tag keys (1-128 chars: letters, digits, spaces, and + - = . _ : / @)."
  }
}

variable "enable_tag_governance" {
  description = "Deploy the tag-governance module (Config rules + tag drift detection + optional untagged-cost report + Allocation Resource Groups). Set false to skip entirely."
  type        = bool
  default     = true
}

variable "tag_governance_record_global_resources" {
  description = "If true, the Config recorder includes global resource types (IAM, CloudFront, Route53). Set false to cut CI volume when you don't need to govern globals."
  type        = bool
  default     = true
}

variable "tag_taxonomy" {
  description = <<-EOT
    Rich metadata per tag key (optional). When supplied, drives the
    untagged-cost report's mandatory list (level = "mandatory" entries) and
    is rendered in the module's documentation outputs. The Config rule is
    still driven by required_tags.
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
      for k, v in var.tag_taxonomy :
      contains(["mandatory", "recommended", "operational"], v.level)
    ])
    error_message = "tag_taxonomy[*].level must be one of: mandatory, recommended, operational."
  }

  validation {
    condition = alltrue([
      for k, v in var.tag_taxonomy :
      contains(["allocation", "compliance", "operational", "lifecycle"], v.purpose)
    ])
    error_message = "tag_taxonomy[*].purpose must be one of: allocation, compliance, operational, lifecycle."
  }
}

variable "enable_tag_drift_detection" {
  description = "Audit mutations of allocation-critical tag keys to the events bus."
  type        = bool
  default     = true
}

variable "tag_drift_watched_keys" {
  description = "Tag keys whose mutations emit an audit event. Default covers the standard FinOps allocation set."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

variable "enable_untagged_cost_report" {
  description = "Deploy a weekly Lambda that dollarizes the tag gap. Requires enable_cost_data_exports + enable_athena_workgroup."
  type        = bool
  default     = false
}

variable "untagged_cost_report_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the untagged-cost report."
  type        = string
  default     = "0 8 ? * MON *"
}

variable "untagged_cost_alarm_threshold_usd" {
  description = "Alarm if the total monthly untagged-cost gap exceeds this value. Null disables the alarm."
  type        = number
  default     = 1000
}

variable "allocation_resource_groups" {
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

variable "tag_compliance_resource_types" {
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
# Budgets
#
# A single polymorphic map. Each entry is one budget; absence means none.
# Scope discriminator drives the cost_filter generated by the module.
###############################################################################

variable "budget_default_thresholds" {
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

variable "enable_budget_performance_tracking" {
  description = "Deploy the daily budget-performance Lambda (variance, burn-rate, adherence score, anomaly correlation, dashboard)."
  type        = bool
  default     = true
}

variable "budget_performance_schedule_cron" {
  description = "EventBridge cron (UTC, six fields) for the budget-performance Lambda."
  type        = string
  default     = "0 7 * * ? *"
}

variable "budget_adherence_alarm_threshold" {
  description = "Alarm if BudgetAdherenceScore (% of budgets within target) drops below this. Null disables."
  type        = number
  default     = 80
}

variable "budget_burn_rate_alarm_days_to_breach" {
  description = "Alarm if any single budget's BurnRateDaysToBreach metric drops below this. Null disables. (Applied as a metric-math alarm on the lowest of all per-budget series.)"
  type        = number
  default     = 7
}

variable "budget_currency" {
  description = "ISO 4217 currency code applied to all budgets (e.g. USD, EUR, GBP)."
  type        = string
  default     = "USD"

  validation {
    condition     = can(regex("^[A-Z]{3}$", var.budget_currency))
    error_message = "budget_currency must be a 3-letter ISO 4217 code (uppercase)."
  }
}

variable "budgets" {
  description = <<-EOT
    Polymorphic budget definitions, keyed by stable identifier.

    Required per entry:
      scope  = "account" | "service" | "tag" | "cost_category"
      amount = number   # limit, in budget_currency unless overridden

    Optional period + currency overrides:
      time_unit = "MONTHLY" | "QUARTERLY" | "ANNUALLY"   (default MONTHLY)
      currency  = ISO 4217 code; overrides budget_currency for this budget only

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
      threshold_pct     = number
      notification_type = optional(string, "ACTUAL")
      action_type       = string
      approval_model    = optional(string, "MANUAL")
      iam_policy_arn    = optional(string)
      iam_roles         = optional(list(string), [])
      iam_groups        = optional(list(string), [])
      iam_users         = optional(list(string), [])
      scp_policy_id     = optional(string)
      scp_target_ids    = optional(list(string), [])
      ssm_action_subtype = optional(string)
      ssm_region        = optional(string)
      ssm_instance_ids  = optional(list(string), [])
      subscribers       = optional(list(string), [])
    })), [])
    owner       = optional(string, "(unowned)")
    approver    = optional(string, "")
    approved_at = optional(string, "")
    purpose     = optional(string, "")
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["account", "service", "tag", "cost_category"], v.scope)
    ])
    error_message = "Each budgets entry's scope must be one of: account, service, tag, cost_category."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["MONTHLY", "QUARTERLY", "ANNUALLY"], v.time_unit)
    ])
    error_message = "Each budgets entry's time_unit must be one of: MONTHLY, QUARTERLY, ANNUALLY."
  }

  validation {
    condition     = alltrue([for k, v in var.budgets : v.amount > 0])
    error_message = "All budgets.*.amount must be > 0."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets : v.scope == "account" || v.target != null
    ])
    error_message = "Non-account budgets require a target."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets :
      v.scope != "service" || (v.target != null && v.target.service != null)
    ])
    error_message = "Scope 'service' budgets require target.service."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets :
      v.scope != "tag" || (v.target != null && v.target.tag_key != null && v.target.tag_value != null)
    ])
    error_message = "Scope 'tag' budgets require target.tag_key and target.tag_value."
  }

  validation {
    condition = alltrue([
      for k, v in var.budgets :
      v.scope != "cost_category" || (v.target != null && v.target.category_name != null && v.target.category_value != null)
    ])
    error_message = "Scope 'cost_category' budgets require target.category_name and target.category_value."
  }
}

###############################################################################
# Anomaly detection
###############################################################################

variable "enable_anomaly_detection" {
  description = "Enable AWS Cost Anomaly Detection (service-level monitor + subscription)."
  type        = bool
  default     = true
}

variable "anomaly_min_impact_amount" {
  description = "Minimum daily anomaly impact (in budget_currency) required to trigger an alert."
  type        = number
  default     = 100

  validation {
    condition     = var.anomaly_min_impact_amount >= 0
    error_message = "anomaly_min_impact_amount must be >= 0."
  }
}

variable "anomaly_min_impact_pct" {
  description = "Minimum daily anomaly impact (% variance) required in addition to anomaly_min_impact_amount. Filters out high-variance low-cost workloads."
  type        = number
  default     = 20

  validation {
    condition     = var.anomaly_min_impact_pct >= 0 && var.anomaly_min_impact_pct <= 100
    error_message = "anomaly_min_impact_pct must be between 0 and 100."
  }
}

###############################################################################
# Cost categories (allocation logic as code)
###############################################################################

variable "cost_categories" {
  description = <<-EOT
    AWS Cost Categories defined as code. Map key is the category name.
    Each entry:
      {
        rule_version  = optional string, default "CostCategoryExpression.v1"
        default_value = optional string, default "unallocated"
        rules         = list of {
          value = string
          rule  = {
            tags      = optional { key, values, match_options }
            dimension = optional { key, values, match_options }
          }
        }
      }
  EOT
  type = map(object({
    rule_version  = optional(string, "CostCategoryExpression.v1")
    default_value = optional(string, "unallocated")
    rules = list(object({
      value = string
      rule = object({
        tags = optional(object({
          key           = string
          values        = list(string)
          match_options = list(string)
        }))
        dimension = optional(object({
          key           = string
          values        = list(string)
          match_options = list(string)
        }))
      })
    }))
  }))
  default = {}
}

###############################################################################
# Optimization services
###############################################################################

variable "enable_compute_optimizer" {
  description = "Enroll the account in AWS Compute Optimizer (free EC2/EBS/Lambda/ASG rightsizing recommendations)."
  type        = bool
  default     = true
}

variable "enable_cost_optimization_hub" {
  description = "Enroll the account in AWS Cost Optimization Hub (consolidated recommendations dashboard)."
  type        = bool
  default     = true
}

###############################################################################
# Idle resource cleanup
###############################################################################

variable "enable_idle_cleanup" {
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
  description = "Regions the idle-resource-cleanup Lambdas iterate over. Empty list = home region only."
  type        = list(string)
  default     = []
}

variable "idle_cleanup_aging_seen_count_threshold" {
  description = "Number of consecutive scans a finding must persist before its severity is bumped to high (signals an ignored finding)."
  type        = number
  default     = 10
}

###############################################################################
# Instance scheduler
###############################################################################

variable "enable_instance_scheduler" {
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
    Named schedules. Cron expressions in UTC (EventBridge six-field syntax).
    Example:
      {
        office-hours-cet = {
          start_cron = "0 6 ? * MON-FRI *"
          stop_cron  = "0 18 ? * MON-FRI *"
        }
      }
  EOT
  type = map(object({
    start_cron = string
    stop_cron  = string
  }))
  default = {
    office-hours-cet = {
      start_cron = "0 6 ? * MON-FRI *"
      stop_cron  = "0 18 ? * MON-FRI *"
    }
    office-hours-est = {
      start_cron = "0 12 ? * MON-FRI *"
      stop_cron  = "0 0 ? * TUE-SAT *"
    }
  }
}

###############################################################################
# Savings coverage reporter
###############################################################################

variable "enable_savings_coverage_reporter" {
  description = "Deploy the weekly Lambda that reports RI and Savings Plan coverage and utilization."
  type        = bool
  default     = true
}

variable "savings_coverage_report_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the coverage reporter."
  type        = string
  default     = "0 9 ? * MON *"
}

variable "savings_coverage_target_pct" {
  description = "Target RI/SP coverage percentage. Reports below this threshold are flagged in the alert payload."
  type        = number
  default     = 70

  validation {
    condition     = var.savings_coverage_target_pct >= 0 && var.savings_coverage_target_pct <= 100
    error_message = "savings_coverage_target_pct must be between 0 and 100."
  }
}

###############################################################################
# FinOps metrics (KPI emission)
###############################################################################

variable "enable_finops_metrics" {
  description = "Deploy the finops-metrics module: Athena named queries + daily KPI aggregator → CloudWatch + SSM. Requires enable_cost_data_exports + enable_athena_workgroup."
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
  description = "Per-KPI alarm thresholds. Set any value to null to skip the alarm."
  type = object({
    allocation_coverage_min_pct     = optional(number, 80)
    commitment_coverage_min_pct     = optional(number, 70)
    commitment_utilization_min_pct  = optional(number, 80)
    forecast_accuracy_max_drift_pct = optional(number, 15)
  })
  default = {}
}

###############################################################################
# Notifications
###############################################################################

variable "notification_emails" {
  description = "Email addresses subscribed to the FinOps events SNS topic."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))
    ])
    error_message = "notification_emails must contain valid email addresses."
  }
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL. Null disables the Slack notifier. SENSITIVE — set as a sensitive variable in TFE, never commit."
  type        = string
  default     = null
  sensitive   = true
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL. Null disables the Teams notifier. SENSITIVE — set as a sensitive variable in TFE, never commit."
  type        = string
  default     = null
  sensitive   = true
}

###############################################################################
# Lambda runtime
###############################################################################

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
# Observability
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
