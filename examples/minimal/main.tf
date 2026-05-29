# =============================================================================
# Minimal Example — FinOps Foundation "Crawl" phase
#
# The smallest viable deployment. Use this to:
#   - Get cost data flowing (CUR 2.0 + Athena)
#   - Catch the most-egregious budget breaches
#   - Build a baseline of cost visibility
# before you have tagging discipline or an allocation strategy.
#
# What it does:
#   - Creates the framework KMS key + events SNS topic
#   - Enables CUR 2.0 + Athena (no FOCUS yet)
#   - Creates a single account-level budget
#   - Sends notifications to email only
#
# What it does NOT do:
#   - Tag governance Config rules (no taxonomy yet)
#   - Tag-based or cost-category-based budgets (need tagging first)
#   - Idle cleanup or instance scheduler (observe mode first)
#   - Slack/Teams notifications (email is enough at this phase)
#   - FinOps KPI emission (needs ≥1 month of CUR data to be useful)
#
# Move to examples/production once: tagging is ≥80% covered, a chargeback
# scheme exists, and you've reviewed at least one month of cost data.
# =============================================================================

module "finops" {
  source = "../../"

  namespace          = "examplebank"
  environment        = "sandbox"
  stack_name         = "finops"
  aws_primary_region = "eu-central-1"

  # --- Minimal cost data -----------------------------------------------------
  cost_data_exports_enabled        = true
  cost_data_exports_focus_enabled  = false
  cost_data_exports_athena_enabled = true

  # --- One account-level budget ----------------------------------------------
  budgets_currency = "USD"
  budgets_items = {
    account_monthly = {
      scope  = "account"
      amount = 5000
    }
  }

  # --- Tag governance off until a taxonomy is decided ------------------------
  tag_governance_enabled = false

  # --- Off for sandbox — turn on once tagging discipline is in place ---------
  idle_cleanup_enabled       = false
  instance_scheduler_enabled = false

  # KPI emission off in Crawl — Athena views need 1+ months of CUR data
  finops_metrics_enabled = false

  # --- Email-only notifications ----------------------------------------------
  alerting_legacy_emails = ["finops@examplebank.com"]

  log_retention_days = 90 # shorter for sandbox
}

output "events_topic_arn" {
  value = module.finops.events_topic_arn
}

output "framework_status" {
  description = "Single-glance status of what's deployed."
  value       = module.finops.framework_status
}
