# =============================================================================
# Production Example — full FinOps capability stack ("Run" phase)
#
# Every available capability is turned on, allocation is wired up, idle/scheduler
# automations are active (still dry-run on first apply), and Slack/Teams
# notifications are configured.
#
# Defaults here lean conservative (7-year log retention, KMS CMK,
# prevent_destroy) so the example is also valid for SOX/PCI/GDPR/DORA-regulated
# workloads. Trim log_retention_days down to 365 (or less) for non-regulated
# accounts.
#
# Usage:
#   1. Set the sensitive variables (alerting_slack_webhook_url,
#      alerting_teams_webhook_url) in your TFE workspace.
#   2. Adjust the values below to match your account / namespace.
#   3. terraform init && terraform plan && terraform apply.
# =============================================================================

module "finops" {
  source = "../../"

  # --- Identity ---
  namespace             = "examplebank"
  environment           = "shared"
  stack_name            = "finops"
  aws_primary_region    = "eu-central-1"
  aws_secondary_regions = ["us-east-1"]

  # --- Encryption: framework creates a dedicated KMS key ---
  create_kms_key               = true
  kms_key_deletion_window_days = 30

  # --- Cost data: CUR 2.0 + FOCUS, 7-year retention ---
  cost_data_exports_enabled         = true
  cost_data_exports_focus_enabled   = true
  cost_data_exports_athena_enabled  = true
  cost_data_exports_retention_days  = 90
  cost_data_exports_expiration_days = 2555

  # --- Tag governance ---
  tag_governance_enabled = true

  tag_governance_required_tags = [
    { key = "CostCenter", allowed_values = [] },
    { key = "Environment", allowed_values = ["prod", "nonprod", "dr", "sandbox"] },
    { key = "Application", allowed_values = [] },
    { key = "Owner", allowed_values = [] },
    { key = "BusinessUnit", allowed_values = ["retail-banking", "investment-banking", "wealth", "corporate", "operations", "technology-shared"] },
    { key = "DataClassification", allowed_values = ["public", "internal", "confidential", "restricted"] },
  ]

  tag_governance_taxonomy = {
    CostCenter         = { level = "mandatory", purpose = "allocation", description = "Finance cost center identifier", examples = ["CC-1234"] }
    BusinessUnit       = { level = "mandatory", purpose = "allocation", description = "Business unit owning the resource", examples = ["retail-banking", "investment-banking"] }
    Application        = { level = "mandatory", purpose = "allocation", description = "Logical application name", examples = ["payments-api"] }
    Owner              = { level = "mandatory", purpose = "lifecycle", description = "Email of the human owner", examples = ["jane@example.com"] }
    Environment        = { level = "mandatory", purpose = "operational", description = "Deployment environment", examples = ["prod", "nonprod"] }
    DataClassification = { level = "recommended", purpose = "compliance", description = "Data sensitivity classification", examples = ["confidential"] }
    Schedule           = { level = "operational", purpose = "operational", description = "Instance scheduler schedule name", examples = ["office-hours-cet"] }
    FinOpsException    = { level = "operational", purpose = "operational", description = "Opt-out of idle cleanup automation", examples = ["true"] }
  }

  tag_governance_drift_detection_enabled = true
  tag_governance_drift_watched_keys      = ["CostCenter", "BusinessUnit", "Application", "Owner"]

  tag_governance_untagged_cost_report_enabled      = true
  tag_governance_untagged_cost_report_cron         = "0 8 ? * MON *"
  tag_governance_untagged_cost_alarm_threshold_usd = 5000

  tag_governance_allocation_resource_groups = {
    bu-retail-banking     = { tag_key = "BusinessUnit", tag_values = ["retail-banking"] }
    bu-investment-banking = { tag_key = "BusinessUnit", tag_values = ["investment-banking"] }
    bu-wealth             = { tag_key = "BusinessUnit", tag_values = ["wealth"] }
    env-prod              = { tag_key = "Environment", tag_values = ["prod"] }
  }

  # --- Budgets ---
  budgets_currency                       = "USD"
  budgets_performance_tracking_enabled   = true
  budgets_adherence_alarm_threshold      = 85
  budgets_burn_rate_alarm_days_to_breach = 7

  budgets_items = {
    account_monthly = {
      scope    = "account"
      amount   = 250000
      owner    = "finops@example.com"
      approver = "cfo@example.com"
      purpose  = "Top-line account cap; FY26"
      thresholds = [
        { pct = 60, type = "ACTUAL" },
        { pct = 80, type = "ACTUAL" },
        { pct = 100, type = "ACTUAL" },
        { pct = 100, type = "FORECASTED" },
      ]
    }
    account_quarterly = {
      scope     = "account"
      amount    = 750000
      time_unit = "QUARTERLY"
      owner     = "finops@example.com"
      purpose   = "Quarterly board reporting line"
    }
    ec2_monthly = {
      scope  = "service"
      amount = 80000
      target = { service = "Amazon Elastic Compute Cloud - Compute" }
      owner  = "platform@example.com"
    }
    rds_monthly = {
      scope  = "service"
      amount = 40000
      target = { service = "Amazon Relational Database Service" }
      owner  = "data-platform@example.com"
    }
    s3_monthly = {
      scope  = "service"
      amount = 15000
      target = { service = "Amazon Simple Storage Service" }
      owner  = "platform@example.com"
    }
    retail_banking_monthly = {
      scope                     = "tag"
      amount                    = 80000
      target                    = { tag_key = "BusinessUnit", tag_value = "retail-banking" }
      owner                     = "retail-banking-finops@example.com"
      extra_notification_emails = ["retail-banking-leadership@example.com"]
    }
    investment_banking_monthly = {
      scope  = "tag"
      amount = 100000
      target = { tag_key = "BusinessUnit", tag_value = "investment-banking" }
      owner  = "investment-banking-finops@example.com"
    }
    # Example: a budget with auto-enforcement via AWS Budget Actions.
    # When this budget breaches 100% (actual), AWS applies a deny-all IAM
    # policy to a sandbox-team IAM group, freezing new resource creation
    # until a human approves. APPROVAL_MODEL = MANUAL means an explicit
    # human approval is still required to execute.
    # Uncomment + adjust ARNs before enabling.
    #
    # sandbox_monthly = {
    #   scope    = "tag"
    #   amount   = 5000
    #   target   = { tag_key = "Environment", tag_value = "sandbox" }
    #   owner    = "platform@example.com"
    #   actions = [
    #     {
    #       threshold_pct  = 100
    #       action_type    = "APPLY_IAM_POLICY"
    #       approval_model = "MANUAL"
    #       iam_policy_arn = "arn:aws:iam::123456789012:policy/DenyAllExceptRead"
    #       iam_groups     = ["sandbox-developers"]
    #       subscribers    = ["sandbox-leads@example.com"]
    #     }
    #   ]
    # }
  }

  # --- Idle cleanup (DRY RUN — KEEP TRUE for first month at minimum) ---
  # Six resource types covered: ebs, eip, snapshot, nat, eni, lb
  # Each emits MonthlyWasteUsd to CloudWatch under FinOps/IdleResources.
  idle_cleanup_enabled = true
  idle_cleanup_dry_run = true

  # --- Instance scheduler ---
  instance_scheduler_enabled = true
  # Blast-radius cap: hard ceiling on mutating actions per tick
  instance_scheduler_max_actions_per_tick = 500

  # --- FinOps KPI emission ---
  finops_metrics_enabled             = true
  finops_metrics_allocation_tag_keys = ["CostCenter", "BusinessUnit", "Application"]
  finops_metrics_alarm_thresholds = {
    allocation_coverage_min_pct     = 85
    commitment_coverage_min_pct     = 70
    commitment_utilization_min_pct  = 80
    forecast_accuracy_max_drift_pct = 10
  }

  # --- Notifications ---
  alerting_legacy_emails = [
    "finops-team@examplebank.com",
    "cloud-platform@examplebank.com",
  ]

  # Sensitive — set in TFE workspace
  alerting_slack_webhook_url = var.slack_webhook_url
  alerting_teams_webhook_url = var.teams_webhook_url

  log_retention_days = 2557
}

# Surface key outputs for downstream consumption
output "kms_key_arn" {
  value = module.finops.kms_key_arn
}

output "events_topic_arn" {
  value = module.finops.events_topic_arn
}

output "framework_status" {
  description = "Single-glance status of what's deployed and where to find dashboards."
  value       = module.finops.framework_status
}

output "enabled_modules" {
  description = "Map of module -> enabled flag (for downstream CI assertions)."
  value       = module.finops.enabled_modules
}

output "cost_data_exports_bucket_name" {
  value = module.finops.cost_data_exports_bucket_name
}

output "cost_data_exports_athena_workgroup_name" {
  value = module.finops.cost_data_exports_athena_workgroup_name
}
