# =============================================================================
# Production Example — full FinOps capability stack ("Run" phase)
#
# Every capability is turned on, allocation is wired up, idle/scheduler
# automations are active (still dry-run on first apply), and Slack/Teams
# notifications are configured.
#
# Defaults here lean conservative (7-year log retention, KMS CMK,
# prevent_destroy) so the example is also valid for SOX/PCI/GDPR/DORA-regulated
# workloads. Trim log_retention_days down to 365 (or less) for non-regulated
# accounts.
#
# Usage:
#   1. Set the sensitive variables (slack_webhook_url, teams_webhook_url) in
#      your TFE workspace.
#   2. Adjust the values below to match your account / namespace.
#   3. terraform init && terraform plan && terraform apply.
# =============================================================================

module "finops" {
  source = "../../"

  # --- Identity ---
  namespace   = "examplebank"
  environment = "shared"
  stack_name  = "finops"
  aws_region  = "eu-central-1"

  # --- Encryption: framework creates a dedicated KMS key ---
  create_kms_key               = true
  kms_key_deletion_window_days = 30

  # --- Cost data: CUR 2.0 + FOCUS, 7-year retention ---
  enable_cost_data_exports  = true
  enable_focus_export       = true
  enable_athena_workgroup   = true
  cost_data_retention_days  = 90
  cost_data_expiration_days = 2555

  # --- Tag governance ---
  required_tags = [
    { key = "CostCenter", allowed_values = [] },
    { key = "Environment", allowed_values = ["prod", "nonprod", "dr", "sandbox"] },
    { key = "Application", allowed_values = [] },
    { key = "Owner", allowed_values = [] },
    { key = "BusinessUnit", allowed_values = ["retail-banking", "investment-banking", "wealth", "corporate", "operations", "technology-shared"] },
    { key = "DataClassification", allowed_values = ["public", "internal", "confidential", "restricted"] },
  ]

  tag_taxonomy = {
    CostCenter         = { level = "mandatory",   purpose = "allocation",  description = "Finance cost center identifier",     examples = ["CC-1234"] }
    BusinessUnit       = { level = "mandatory",   purpose = "allocation",  description = "Business unit owning the resource",  examples = ["retail-banking", "investment-banking"] }
    Application        = { level = "mandatory",   purpose = "allocation",  description = "Logical application name",           examples = ["payments-api"] }
    Owner              = { level = "mandatory",   purpose = "lifecycle",   description = "Email of the human owner",           examples = ["jane@example.com"] }
    Environment        = { level = "mandatory",   purpose = "operational", description = "Deployment environment",             examples = ["prod", "nonprod"] }
    DataClassification = { level = "recommended", purpose = "compliance",  description = "Data sensitivity classification",    examples = ["confidential"] }
    Schedule           = { level = "operational", purpose = "operational", description = "Instance scheduler schedule name",   examples = ["office-hours-cet"] }
    FinOpsException    = { level = "operational", purpose = "operational", description = "Opt-out of idle cleanup automation", examples = ["true"] }
  }

  enable_tag_drift_detection = true
  tag_drift_watched_keys     = ["CostCenter", "BusinessUnit", "Application", "Owner"]

  enable_untagged_cost_report       = true
  untagged_cost_report_cron         = "0 8 ? * MON *"
  untagged_cost_alarm_threshold_usd = 5000

  allocation_resource_groups = {
    bu-retail-banking      = { tag_key = "BusinessUnit", tag_values = ["retail-banking"] }
    bu-investment-banking  = { tag_key = "BusinessUnit", tag_values = ["investment-banking"] }
    bu-wealth              = { tag_key = "BusinessUnit", tag_values = ["wealth"] }
    env-prod               = { tag_key = "Environment",  tag_values = ["prod"] }
  }

  # --- Budgets ---
  budget_currency = "USD"
  budgets = {
    account_monthly = {
      scope  = "account"
      amount = 250000
    }
    ec2_monthly = {
      scope  = "service"
      amount = 80000
      target = { service = "Amazon Elastic Compute Cloud - Compute" }
    }
    rds_monthly = {
      scope  = "service"
      amount = 40000
      target = { service = "Amazon Relational Database Service" }
    }
    s3_monthly = {
      scope  = "service"
      amount = 15000
      target = { service = "Amazon Simple Storage Service" }
    }
    retail_banking_monthly = {
      scope  = "tag"
      amount = 80000
      target = { tag_key = "BusinessUnit", tag_value = "retail-banking" }
    }
    investment_banking_monthly = {
      scope  = "tag"
      amount = 100000
      target = { tag_key = "BusinessUnit", tag_value = "investment-banking" }
    }
  }

  # --- Anomaly detection ---
  enable_anomaly_detection  = true
  anomaly_min_impact_amount = 250
  anomaly_min_impact_pct    = 20

  # --- Cost categories ---
  cost_categories = {
    BusinessUnit = {
      default_value = "unallocated"
      rules = [
        {
          value = "retail-banking"
          rule = {
            tags = {
              key           = "BusinessUnit"
              values        = ["retail-banking", "retail"]
              match_options = ["EQUALS"]
            }
          }
        },
        {
          value = "investment-banking"
          rule = {
            tags = {
              key           = "BusinessUnit"
              values        = ["investment-banking", "ib", "markets"]
              match_options = ["EQUALS"]
            }
          }
        },
      ]
    }
  }

  # --- Optimization services ---
  enable_compute_optimizer     = true
  enable_cost_optimization_hub = true

  # --- Idle cleanup (DRY RUN — KEEP TRUE for first month at minimum) ---
  # Six resource types covered: ebs, eip, snapshot, nat, eni, lb
  # Each emits MonthlyWasteUsd to CloudWatch under FinOps/IdleResources.
  enable_idle_cleanup  = true
  idle_cleanup_dry_run = true

  # --- Instance scheduler ---
  enable_instance_scheduler = true

  # --- Savings coverage reporting ---
  enable_savings_coverage_reporter = true
  savings_coverage_target_pct      = 70

  # --- FinOps KPI emission ---
  enable_finops_metrics              = true
  finops_metrics_allocation_tag_keys = ["CostCenter", "BusinessUnit", "Application"]
  finops_metrics_alarm_thresholds = {
    allocation_coverage_min_pct     = 85
    commitment_coverage_min_pct     = 70
    commitment_utilization_min_pct  = 80
    forecast_accuracy_max_drift_pct = 10
  }

  # --- Notifications ---
  notification_emails = [
    "finops-team@examplebank.com",
    "cloud-platform@examplebank.com",
  ]

  # Sensitive — set in TFE workspace
  slack_webhook_url = var.slack_webhook_url
  teams_webhook_url = var.teams_webhook_url

  log_retention_days = 2557
}

# Surface key outputs for downstream consumption
output "kms_key_arn" {
  value = module.finops.kms_key_arn
}

output "events_topic_arn" {
  value = module.finops.events_topic_arn
}

output "cost_data_bucket_name" {
  value = module.finops.cost_data_bucket_name
}

output "athena_workgroup_name" {
  value = module.finops.athena_workgroup_name
}
