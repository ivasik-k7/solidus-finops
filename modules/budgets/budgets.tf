###############################################################################
# AWS Budgets — one resource per entry in var.budgets + actions
#
# Polymorphism is in the cost_filter and the optional thresholds list:
#   - account scope        no cost_filter
#   - service scope        cost_filter Service = [v.target.service]
#   - tag scope            cost_filter TagKeyValue = ["user:K$V"]
#   - cost_category scope  cost_filter CostCategory = ["NAME$VALUE"]
#
# Budget Actions get a separate aws_budgets_budget_action per entry in each
# budget's actions list, dispatched via the flattened locals.actions_map.
###############################################################################

resource "aws_budgets_budget" "this" {
  for_each = var.budgets

  name              = "${var.name_prefix}-${each.key}"
  budget_type       = "COST"
  limit_amount      = tostring(each.value.amount)
  limit_unit        = coalesce(each.value.currency, var.currency)
  time_unit         = each.value.time_unit
  time_period_start = local.period_start[each.value.time_unit]

  # ---- Filter target by scope ----
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

  # ---- Notifications (custom per-budget or default ladder) ----
  dynamic "notification" {
    for_each = length(each.value.thresholds) > 0 ? each.value.thresholds : var.default_thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.pct
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_sns_topic_arns  = [var.events_topic_arn]
      subscriber_email_addresses = each.value.extra_notification_emails
    }
  }

  tags = merge(
    var.default_tags,
    {
      BudgetOwner    = each.value.owner
      BudgetApprover = each.value.approver
      BudgetApproved = each.value.approved_at
      BudgetPurpose  = each.value.purpose
      BudgetScope    = each.value.scope
    },
  )

  lifecycle {
    ignore_changes = [time_period_start]
  }
}

# ---------------------------------------------------------------------------
# Budget Actions — auto-enforcement on threshold breach
# ---------------------------------------------------------------------------

resource "aws_budgets_budget_action" "this" {
  for_each = local.actions_map

  account_id  = data.aws_caller_identity.current.account_id
  budget_name = aws_budgets_budget.this[each.value.budget_key].name

  action_type        = each.value.action.action_type
  approval_model     = each.value.action.approval_model
  notification_type  = each.value.action.notification_type
  execution_role_arn = aws_iam_role.budget_actions[0].arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = each.value.action.threshold_pct
  }

  dynamic "definition" {
    for_each = each.value.action.action_type == "APPLY_IAM_POLICY" ? [1] : []
    content {
      iam_action_definition {
        policy_arn = each.value.action.iam_policy_arn
        roles      = each.value.action.iam_roles
        groups     = each.value.action.iam_groups
        users      = each.value.action.iam_users
      }
    }
  }

  dynamic "definition" {
    for_each = each.value.action.action_type == "APPLY_SCP_POLICY" ? [1] : []
    content {
      scp_action_definition {
        policy_id  = each.value.action.scp_policy_id
        target_ids = each.value.action.scp_target_ids
      }
    }
  }

  dynamic "definition" {
    for_each = each.value.action.action_type == "RUN_SSM_DOCUMENTS" ? [1] : []
    content {
      ssm_action_definition {
        action_sub_type = each.value.action.ssm_action_subtype
        region          = each.value.action.ssm_region
        instance_ids    = each.value.action.ssm_instance_ids
      }
    }
  }

  # SNS subscriber → events bus (always present)
  subscriber {
    subscription_type = "SNS"
    address           = var.events_topic_arn
  }

  # Additional per-action email subscribers
  dynamic "subscriber" {
    for_each = toset(each.value.action.subscribers)
    content {
      subscription_type = "EMAIL"
      address           = subscriber.value
    }
  }
}
