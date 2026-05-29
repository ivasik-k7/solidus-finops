# =============================================================================
# Minimal Example — FinOps Foundation "Crawl" phase
#
# The smallest viable deployment. Use this to:
#   - Get cost data flowing (CUR 2.0 + Athena)
#   - Catch the most-egregious anomalies and budget breaches
#   - Surface free optimization recommendations (Compute Optimizer, Cost Opt Hub)
# before you have tagging discipline or an allocation strategy.
#
# What it does:
#   - Creates the KMS key
#   - Enables CUR 2.0 + Athena (no FOCUS yet)
#   - Creates a single account-level budget
#   - Wires anomaly detection
#   - Enables Compute Optimizer + Cost Optimization Hub
#   - Sends notifications to email only
#
# What it does NOT do:
#   - Tag-based or cost-category-based budgets (need tagging first)
#   - Cost categories (need allocation strategy first)
#   - Idle cleanup or instance scheduler (observe mode first)
#   - Slack/Teams notifications (email is enough at this phase)
#
# Move to examples/production once: tagging is ≥80% covered, a chargeback
# scheme exists, and you've reviewed at least one month of anomaly findings.
# =============================================================================

module "finops" {
  source = "../../"

  namespace   = "examplebank"
  environment = "sandbox"
  stack_name  = "finops"
  aws_region  = "eu-central-1"

  # Minimal cost data
  enable_cost_data_exports = true
  enable_focus_export      = false
  enable_athena_workgroup  = true

  # One account-level budget
  budget_currency = "USD"
  budgets = {
    account_monthly = {
      scope  = "account"
      amount = 5000
    }
  }

  # Anomaly detection on, lower threshold for sandbox
  enable_anomaly_detection  = true
  anomaly_min_impact_amount = 50
  anomaly_min_impact_pct    = 20

  # No cost categories yet
  cost_categories = {}

  # Free optimization services
  enable_compute_optimizer     = true
  enable_cost_optimization_hub = true

  # OFF for sandbox — turn on once you have tagging discipline
  enable_idle_cleanup              = false
  enable_instance_scheduler        = false
  enable_savings_coverage_reporter = false

  # KPI emission off in Crawl — Athena views are useful once CUR has 1+ months of data
  enable_finops_metrics = false

  # Email-only notifications
  notification_emails = ["finops@examplebank.com"]

  log_retention_days = 90 # shorter for sandbox
}
