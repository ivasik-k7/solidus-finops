# =============================================================================
# Selective Deployment Example
#
# Demonstrates how to deploy only the modules you actually want and leave
# every other module disabled. Toggle them on later by flipping a single
# `<module>_enabled` flag — no other code changes required.
#
# This particular configuration enables:
#   ✅ alerting                — events SNS bus (always on; required infra)
#   ✅ budgets                 — polymorphic budgets + Budget Actions + DDB + dashboard
#   ✅ idle-resource-cleanup   — 6 resource types + multi-region + DDB audit
#   ✅ tag-governance          — required tags + drift + Resource Groups
#
# And disables:
#   ❌ cost-data-exports       — no CUR / FOCUS / Athena (also disables anything
#                                 that needs Athena — finops-metrics, untagged-cost)
#   ❌ instance-scheduler
#   ❌ finops-metrics          — needs cost-data-exports + Athena anyway
#
# Always-on (cannot be disabled):
#   • alerting        — events SNS bus + chat-notifier (everything publishes here)
#   • KMS CMK         — encrypts everything; turning it off would break compliance
#
# To enable a disabled module, just flip its `<module>_enabled = true`. Pass any
# module-specific variables you need; defaults work for the rest.
# =============================================================================

module "finops" {
  source = "../../"

  # === Identity ==============================================================
  namespace          = "examplecorp"
  environment        = "shared"
  stack_name         = "finops"
  aws_primary_region = "eu-central-1"

  # === Encryption (always on) ================================================
  create_kms_key               = true
  kms_key_deletion_window_days = 30

  # ---------------------------------------------------------------------------
  # DISABLED MODULES — flip to true to enable
  # ---------------------------------------------------------------------------

  # Cost & Usage Reports — no CUR/FOCUS/Athena. Disable also implies no
  # downstream finops-metrics and no untagged-cost-report.
  cost_data_exports_enabled = false
  # cost_data_exports_focus_enabled  = true   # only meaningful when CUR exports are on
  # cost_data_exports_athena_enabled = true

  # Instance scheduler — tag-driven EC2 / RDS / ASG start/stop.
  instance_scheduler_enabled = false
  # instance_scheduler_opt_in_tag_key = "Schedule"
  # instance_scheduler_schedules = {
  #   office-hours-cet = {
  #     days     = ["MON", "TUE", "WED", "THU", "FRI"]
  #     start    = "08:00"
  #     stop     = "18:00"
  #     timezone = "Europe/Berlin"
  #   }
  # }

  # FinOps metrics — daily KPI aggregator + Athena named queries.
  # Requires cost_data_exports_enabled = true to function.
  finops_metrics_enabled = false

  # ---------------------------------------------------------------------------
  # ENABLED MODULES
  # ---------------------------------------------------------------------------

  # === Tag governance ========================================================
  tag_governance_enabled                 = true
  tag_governance_record_global_resources = false # skip IAM/CloudFront/Route53 to keep Config volume down

  tag_governance_required_tags = [
    { key = "CostCenter", allowed_values = [] },
    { key = "Environment", allowed_values = ["prod", "nonprod", "sandbox"] },
    { key = "Owner", allowed_values = [] },
    { key = "Application", allowed_values = [] },
  ]

  tag_governance_taxonomy = {
    CostCenter  = { level = "mandatory", purpose = "allocation", description = "Finance cost center ID", examples = ["CC-1001"] }
    Environment = { level = "mandatory", purpose = "operational", description = "Deployment environment" }
    Owner       = { level = "mandatory", purpose = "lifecycle", description = "Email of the human owner" }
    Application = { level = "mandatory", purpose = "allocation", description = "Logical application name" }
  }

  tag_governance_drift_detection_enabled = true
  tag_governance_drift_watched_keys      = ["CostCenter", "Owner"]

  # Untagged-cost report requires Athena, which is off here. Leave disabled.
  tag_governance_untagged_cost_report_enabled = false

  tag_governance_allocation_resource_groups = {
    env-prod    = { tag_key = "Environment", tag_values = ["prod"] }
    env-nonprod = { tag_key = "Environment", tag_values = ["nonprod"] }
  }

  # === Budgets ===============================================================
  budgets_currency                     = "USD"
  budgets_performance_tracking_enabled = true
  budgets_adherence_alarm_threshold    = 85

  budgets_items = {
    account_monthly = {
      scope    = "account"
      amount   = 50000
      owner    = "finops@examplecorp.com"
      approver = "cfo@examplecorp.com"
      purpose  = "Account-wide monthly cap"
      thresholds = [
        { pct = 60, type = "ACTUAL" },
        { pct = 85, type = "ACTUAL" },
        { pct = 100, type = "ACTUAL" },
        { pct = 100, type = "FORECASTED" },
      ]
    }
    ec2_monthly = {
      scope  = "service"
      amount = 15000
      target = { service = "Amazon Elastic Compute Cloud - Compute" }
      owner  = "platform@examplecorp.com"
    }
    rds_monthly = {
      scope  = "service"
      amount = 8000
      target = { service = "Amazon Relational Database Service" }
      owner  = "data-platform@examplecorp.com"
    }
  }

  # === Idle resource cleanup =================================================
  # Off by default at the root variable level — turn on here.
  idle_cleanup_enabled = true
  idle_cleanup_dry_run = true # KEEP TRUE until you've reviewed at least one weekly cycle

  # Multi-region scanning (empty = home region only)
  idle_cleanup_scan_regions = [] # add ["us-east-1", "ap-southeast-1"] when ready

  # Per-resource thresholds (defaults usually fine)
  idle_cleanup_ebs_min_age_days      = 14
  idle_cleanup_snapshot_min_age_days = 90

  # ---------------------------------------------------------------------------
  # Notifications (always on — events bus is required for anything to fan out)
  # ---------------------------------------------------------------------------
  alerting_legacy_emails = ["finops@examplecorp.com"]

  # Sensitive — set in TFE workspace variables, not here:
  # alerting_slack_webhook_url = var.slack_webhook_url
  # alerting_teams_webhook_url = var.teams_webhook_url

  # ---------------------------------------------------------------------------
  # Observability
  # ---------------------------------------------------------------------------
  log_retention_days = 365 # 1y — bump to 1827 (5y) / 2557 (7y) for regulated workloads

  # Extra tags merged into framework defaults + applied to every resource
  extra_tags = {
    Project = "finops-platform"
    Owner   = "finops-team"
  }
}

# Surface the enabled modules' key outputs so downstream workspaces can consume.
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

output "budgets_dashboard_name" {
  description = "CloudWatch dashboard for budget performance."
  value       = module.finops.budgets_dashboard_name
}

output "idle_cleanup_dashboard_name" {
  description = "CloudWatch dashboard for idle-resource-cleanup."
  value       = module.finops.idle_cleanup_dashboard_name
}

output "tag_governance_config_rule_names" {
  value = module.finops.tag_governance_config_rule_names
}

output "lambda_dlq_arns" {
  description = "ARNs of every Lambda DLQ — wire your monitoring tool here."
  value       = module.finops.lambda_dlq_arns
}
