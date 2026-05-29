# =============================================================================
# Selective Deployment Example
#
# Demonstrates how to deploy only the modules you actually want and leave
# every other module disabled. Toggle them on later by flipping a single
# enable_* flag — no other code changes required.
#
# This particular configuration enables:
#   ✅ budgets                  — polymorphic budgets + Budget Actions + DDB + dashboard
#   ✅ idle-resource-cleanup    — 6 resource types + multi-region + DDB audit
#   ✅ tag-governance           — required tags + drift + Resource Groups
#
# And disables:
#   ❌ cost-data-exports        — no CUR / FOCUS / Athena (also disables anything
#                                  that needs Athena — finops-metrics, untagged-cost)
#   ❌ anomaly-detection
#   ❌ cost-categories          — implicit: no entries in var.cost_categories
#   ❌ optimization-services    — Compute Optimizer + Cost Optimization Hub off
#   ❌ instance-scheduler
#   ❌ savings-coverage-reporter
#   ❌ finops-metrics
#
# Always-on (cannot be disabled):
#   • alerting        — events SNS bus + chat-notifier (everything publishes here)
#   • KMS CMK         — encrypts everything; turning it off would break compliance
#
# To enable a disabled module, just flip its `enable_<name> = true`. Pass any
# module-specific variables you need; defaults work for the rest.
# =============================================================================

module "finops" {
  source = "../../"

  # === Identity ==============================================================
  namespace   = "examplecorp"
  environment = "shared"
  stack_name  = "finops"
  aws_region  = "eu-central-1"

  # === Encryption (always on) ================================================
  create_kms_key               = true
  kms_key_deletion_window_days = 30

  # ---------------------------------------------------------------------------
  # DISABLED MODULES — flip to true to enable
  # ---------------------------------------------------------------------------

  # Cost & Usage Reports — no CUR/FOCUS/Athena. Disable also implies no
  # downstream finops-metrics and no untagged-cost-report.
  enable_cost_data_exports = false
  # enable_focus_export      = true       # only meaningful when CUR exports are on
  # enable_athena_workgroup  = true

  # Anomaly detection — Cost Anomaly Detection service-level monitor.
  enable_anomaly_detection = false
  # anomaly_min_impact_amount = 100
  # anomaly_min_impact_pct    = 20

  # Optimization services — Compute Optimizer + Cost Optimization Hub (both free).
  enable_compute_optimizer     = false
  enable_cost_optimization_hub = false

  # Instance scheduler — tag-driven EC2 start/stop.
  enable_instance_scheduler = false
  # instance_scheduler_opt_in_tag_key = "Schedule"
  # instance_scheduler_schedules = {
  #   office-hours-cet = {
  #     start_cron = "0 6 ? * MON-FRI *"
  #     stop_cron  = "0 18 ? * MON-FRI *"
  #   }
  # }

  # Savings coverage reporter — weekly RI/SP coverage + utilization digest.
  enable_savings_coverage_reporter = false
  # savings_coverage_target_pct = 70

  # FinOps metrics — daily KPI aggregator + Athena named queries.
  # Requires enable_cost_data_exports = true to function.
  enable_finops_metrics = false

  # Cost categories — implicit toggle: empty map = module not deployed.
  cost_categories = {}

  # ---------------------------------------------------------------------------
  # ENABLED MODULES
  # ---------------------------------------------------------------------------

  # === Tag governance ========================================================
  enable_tag_governance                   = true
  tag_governance_record_global_resources  = false  # skip IAM/CloudFront/Route53 to keep Config volume down

  required_tags = [
    { key = "CostCenter",   allowed_values = [] },
    { key = "Environment",  allowed_values = ["prod", "nonprod", "sandbox"] },
    { key = "Owner",        allowed_values = [] },
    { key = "Application",  allowed_values = [] },
  ]

  tag_taxonomy = {
    CostCenter  = { level = "mandatory", purpose = "allocation",  description = "Finance cost center ID", examples = ["CC-1001"] }
    Environment = { level = "mandatory", purpose = "operational", description = "Deployment environment" }
    Owner       = { level = "mandatory", purpose = "lifecycle",   description = "Email of the human owner" }
    Application = { level = "mandatory", purpose = "allocation",  description = "Logical application name" }
  }

  enable_tag_drift_detection = true
  tag_drift_watched_keys     = ["CostCenter", "Owner"]

  # Untagged-cost report requires Athena, which is off here. Leave disabled.
  enable_untagged_cost_report = false

  allocation_resource_groups = {
    env-prod    = { tag_key = "Environment", tag_values = ["prod"] }
    env-nonprod = { tag_key = "Environment", tag_values = ["nonprod"] }
  }

  # === Budgets ===============================================================
  budget_currency                    = "USD"
  enable_budget_performance_tracking = true
  budget_adherence_alarm_threshold   = 85

  budgets = {
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
  enable_idle_cleanup  = true
  idle_cleanup_dry_run = true   # KEEP TRUE until you've reviewed at least one weekly cycle

  # Multi-region scanning (empty = home region only)
  idle_cleanup_scan_regions = []  # add ["us-east-1", "ap-southeast-1"] when ready

  # Per-resource thresholds (defaults usually fine)
  idle_cleanup_ebs_min_age_days      = 14
  idle_cleanup_snapshot_min_age_days = 90

  # ---------------------------------------------------------------------------
  # Notifications (always on — events bus is required for anything to fan out)
  # ---------------------------------------------------------------------------
  notification_emails = ["finops@examplecorp.com"]

  # Sensitive — set in TFE workspace variables, not here:
  # slack_webhook_url = var.slack_webhook_url
  # teams_webhook_url = var.teams_webhook_url

  # ---------------------------------------------------------------------------
  # Observability
  # ---------------------------------------------------------------------------
  log_retention_days = 365  # 1y — bump to 1827 (5y) / 2557 (7y) for regulated workloads

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

output "budget_dashboard_name" {
  description = "CloudWatch dashboard for budget performance."
  value       = module.finops.budget_dashboard_name
}

output "idle_cleanup_dashboard_name" {
  description = "CloudWatch dashboard for idle-resource-cleanup."
  value       = module.finops.idle_cleanup_dashboard_name
}

output "tag_compliance_config_rule_names" {
  value = module.finops.tag_compliance_config_rule_names
}

output "lambda_dlq_arns" {
  description = "ARNs of every Lambda DLQ — wire your monitoring tool here."
  value       = module.finops.lambda_dlq_arns
}
