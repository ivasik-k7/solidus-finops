###############################################################################
# Locals — period anchors + flattened action map
#
# AWS Budgets needs a valid `time_period_start`. We anchor to the start of
# the current month (or year for annual budgets). The budget resources use
# `lifecycle.ignore_changes = [time_period_start]` so re-applies don't
# constantly drift the field.
###############################################################################

locals {
  metric_namespace = "FinOps/Budgets"
  ssm_prefix       = "/${var.name_prefix}/budgets"

  current_year        = formatdate("YYYY", timestamp())
  current_year_start  = "${local.current_year}-01-01_00:00"
  current_month_start = formatdate("YYYY-MM-01_00:00", timestamp())

  # Per-time-unit anchor.
  period_start = {
    MONTHLY   = local.current_month_start
    QUARTERLY = local.current_month_start
    ANNUALLY  = local.current_year_start
  }

  # Flatten per-budget actions into a single map keyed by "<budget>-action-<idx>".
  flattened_actions = flatten([
    for budget_key, budget in var.budgets : [
      for action_idx, action in budget.actions : {
        key        = "${budget_key}-action-${action_idx}"
        budget_key = budget_key
        action     = action
      }
    ]
  ])

  actions_map = { for a in local.flattened_actions : a.key => a }
}
