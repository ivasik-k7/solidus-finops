###############################################################################
# Optimization Services module
#
# Enrolls the account in:
#   - AWS Compute Optimizer (EC2/EBS/Lambda/ASG rightsizing recommendations)
#   - AWS Cost Optimization Hub (consolidated recommendations dashboard)
#
# Both are free services. Compute Optimizer enhanced infrastructure metrics
# (CloudWatch agent data, 14d → 93d lookback) requires opt-in per resource
# and is a separate, paid feature — not enabled here by default.
###############################################################################

variable "enable_compute_optimizer"     { type = bool }
variable "enable_cost_optimization_hub" { type = bool }

###############################################################################
# Compute Optimizer
###############################################################################

resource "aws_computeoptimizer_enrollment_status" "this" {
  count  = var.enable_compute_optimizer ? 1 : 0
  status = "Active"

  # Single-account scope: do NOT include member accounts unless this is the
  # org management account and you have an explicit decision to do so.
  include_member_accounts = false
}

###############################################################################
# Cost Optimization Hub
###############################################################################

resource "aws_costoptimizationhub_enrollment_status" "this" {
  count = var.enable_cost_optimization_hub ? 1 : 0

  include_member_accounts = false
}

# Preferences for the Hub: surface savings using amortized rates (so
# committed-spend discounts are properly reflected in recommendations).
resource "aws_costoptimizationhub_preferences" "this" {
  count = var.enable_cost_optimization_hub ? 1 : 0

  member_account_discount_visibility = "All"
  savings_estimation_mode            = "AfterDiscounts"

  depends_on = [aws_costoptimizationhub_enrollment_status.this]
}

###############################################################################
# Outputs
###############################################################################

output "compute_optimizer_status" {
  value = var.enable_compute_optimizer ? aws_computeoptimizer_enrollment_status.this[0].status : null
}

output "cost_optimization_hub_enrolled" {
  value = var.enable_cost_optimization_hub
}
