###############################################################################
# Budgets module
#
# Consumes a single polymorphic `budgets` map. The scope discriminator drives
# the cost_filter block. All budgets share the same notification ladder
# (50/80/100% actual, 100% forecast) routed to the events SNS topic.
###############################################################################

variable "name_prefix"      { type = string }
variable "events_topic_arn" { type = string }
variable "currency"         { type = string }
variable "budgets" {
  type = map(object({
    scope  = string
    amount = number
    target = optional(object({
      service        = optional(string)
      tag_key        = optional(string)
      tag_value      = optional(string)
      category_name  = optional(string)
      category_value = optional(string)
    }))
  }))
}
variable "default_tags" { type = map(string) }

locals {
  thresholds = [
    { threshold = 50, type = "ACTUAL" },
    { threshold = 80, type = "ACTUAL" },
    { threshold = 100, type = "ACTUAL" },
    { threshold = 100, type = "FORECASTED" },
  ]

  # Anchor every budget to the first day of the current calendar month on
  # first apply. The lifecycle ignore_changes below prevents perpetual drift
  # on subsequent plans as the clock advances.
  current_month_start = formatdate("YYYY-MM-01_00:00", timestamp())
}

###############################################################################
# One resource handles all scopes via dynamic cost_filter blocks.
###############################################################################

resource "aws_budgets_budget" "this" {
  for_each = var.budgets

  name              = "${var.name_prefix}-${each.key}"
  budget_type       = "COST"
  limit_amount      = tostring(each.value.amount)
  limit_unit        = var.currency
  time_unit         = "MONTHLY"
  time_period_start = local.current_month_start

  dynamic "cost_filter" {
    for_each = each.value.scope == "service" ? [each.value.target] : []
    content {
      name   = "Service"
      values = [cost_filter.value.service]
    }
  }

  dynamic "cost_filter" {
    for_each = each.value.scope == "tag" ? [each.value.target] : []
    content {
      name   = "TagKeyValue"
      values = ["user:${cost_filter.value.tag_key}$${cost_filter.value.tag_value}"]
    }
  }

  dynamic "cost_filter" {
    for_each = each.value.scope == "cost_category" ? [each.value.target] : []
    content {
      name   = "CostCategory"
      values = ["${cost_filter.value.category_name}$${cost_filter.value.category_value}"]
    }
  }

  dynamic "notification" {
    for_each = local.thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.type
      subscriber_sns_topic_arns = [var.events_topic_arn]
    }
  }

  lifecycle {
    ignore_changes = [time_period_start]
  }

  tags = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "budget_ids" {
  description = "Map of budget key -> Budgets resource ID."
  value       = { for k, v in aws_budgets_budget.this : k => v.id }
}

output "budget_names" {
  description = "Map of budget key -> budget name (useful for CloudWatch alarms or Budget Actions)."
  value       = { for k, v in aws_budgets_budget.this : k => v.name }
}
