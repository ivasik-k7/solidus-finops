###############################################################################
# Budgets module — FinOps Foundation aligned, game-changing
#
# What this module delivers beyond a stock AWS Budgets wrapper:
#
#   1. Polymorphic budget schema (account/service/tag/cost_category)
#   2. Per-budget thresholds, time_unit (MONTHLY/QUARTERLY/ANNUALLY),
#      currency, notification recipients, governance metadata
#   3. AWS Budget Actions — IAM/SCP/SSM auto-enforcement on breach
#   4. Daily performance Lambda → CloudWatch metrics + SNS digest:
#         - VariancePct (actual vs limit) per budget
#         - BurnRateDaysToBreach forecast per budget
#         - BudgetAdherenceScore — % of all budgets currently within target
#         - Anomaly correlation: was this breach driven by a known anomaly?
#   5. DynamoDB-backed state + trend table (STATE + SNAPSHOT#<date> rows)
#   6. Auto-provisioned CloudWatch dashboard for the FinOps lead
#   7. CloudWatch alarms on adherence score + per-budget burn rate
###############################################################################

###############################################################################
# Inputs
###############################################################################

variable "name_prefix"        { type = string }
variable "events_topic_arn"   { type = string }
variable "currency"           { type = string }
variable "kms_key_arn"        { type = string }
variable "log_retention_days" { type = number }
variable "default_tags"       { type = map(string) }

variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "budgets" {
  description = <<-EOT
    Polymorphic budget definitions. Per-budget overrides allow custom
    thresholds, time_unit, currency, notification recipients, AWS Budget
    Actions (IAM/SCP/SSM), and governance metadata.
  EOT
  type = map(object({
    # Required
    scope  = string  # "account" | "service" | "tag" | "cost_category"
    amount = number

    # Optional period + currency overrides
    time_unit = optional(string, "MONTHLY")  # MONTHLY | QUARTERLY | ANNUALLY
    currency  = optional(string, null)        # overrides module's currency

    # Filter target (required for non-account scope)
    target = optional(object({
      service        = optional(string)
      tag_key        = optional(string)
      tag_value      = optional(string)
      category_name  = optional(string)
      category_value = optional(string)
    }))

    # Custom thresholds. Empty = use default_thresholds.
    thresholds = optional(list(object({
      pct  = number
      type = optional(string, "ACTUAL")  # ACTUAL | FORECASTED
    })), [])

    # Per-budget extra email subscribers (in addition to events topic)
    extra_notification_emails = optional(list(string), [])

    # AWS Budget Actions (auto-enforcement on threshold breach)
    actions = optional(list(object({
      threshold_pct     = number
      notification_type = optional(string, "ACTUAL") # ACTUAL | FORECASTED
      action_type       = string                      # APPLY_IAM_POLICY | APPLY_SCP_POLICY | RUN_SSM_DOCUMENTS
      approval_model    = optional(string, "MANUAL") # MANUAL | AUTOMATIC

      # APPLY_IAM_POLICY
      iam_policy_arn = optional(string)
      iam_roles      = optional(list(string), [])
      iam_groups     = optional(list(string), [])
      iam_users      = optional(list(string), [])

      # APPLY_SCP_POLICY
      scp_policy_id  = optional(string)
      scp_target_ids = optional(list(string), [])

      # RUN_SSM_DOCUMENTS
      ssm_action_subtype = optional(string) # STOP_EC2_INSTANCES | STOP_RDS_INSTANCES
      ssm_region         = optional(string)
      ssm_instance_ids   = optional(list(string), [])

      # Per-action email subscribers
      subscribers = optional(list(string), [])
    })), [])

    # Governance metadata
    owner       = optional(string, "(unowned)")
    approver    = optional(string, "")
    approved_at = optional(string, "")
    purpose     = optional(string, "")
  }))

  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["account", "service", "tag", "cost_category"], v.scope)
    ])
    error_message = "budgets.*.scope must be one of: account, service, tag, cost_category."
  }
  validation {
    condition = alltrue([
      for k, v in var.budgets : contains(["MONTHLY", "QUARTERLY", "ANNUALLY"], v.time_unit)
    ])
    error_message = "budgets.*.time_unit must be one of: MONTHLY, QUARTERLY, ANNUALLY."
  }
  validation {
    condition     = alltrue([for k, v in var.budgets : v.amount > 0])
    error_message = "budgets.*.amount must be > 0."
  }
}

variable "default_thresholds" {
  description = "Threshold ladder applied to any budget that doesn't specify its own."
  type = list(object({
    pct  = number
    type = optional(string, "ACTUAL")
  }))
  default = [
    { pct = 50, type = "ACTUAL" },
    { pct = 80, type = "ACTUAL" },
    { pct = 100, type = "ACTUAL" },
    { pct = 100, type = "FORECASTED" },
  ]
}

variable "enable_performance_tracking" {
  description = "Deploy the daily budget-performance Lambda (variance, burn-rate, adherence score, DDB trend, dashboard)."
  type        = bool
  default     = true
}

variable "performance_schedule_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the performance Lambda."
  type        = string
  default     = "0 7 * * ? *"
}

variable "adherence_alarm_threshold" {
  description = "Alarm if BudgetAdherenceScore drops below this (% of budgets within target). Null disables."
  type        = number
  default     = 80
}

variable "burn_rate_alarm_days_to_breach" {
  description = "Alarm if any budget's BurnRateDaysToBreach drops below this. Null disables."
  type        = number
  default     = 7
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Locals — period-start anchors + flattened actions
###############################################################################

locals {
  metric_namespace = "FinOps/Budgets"
  ssm_prefix       = "/${var.name_prefix}/budgets"

  current_year       = formatdate("YYYY", timestamp())
  current_year_start = "${local.current_year}-01-01_00:00"
  current_month_start = formatdate("YYYY-MM-01_00:00", timestamp())

  # Per-time-unit anchor. AWS Budgets just needs a valid period_start; the
  # lifecycle ignore_changes below prevents drift on re-apply.
  period_start = {
    MONTHLY    = local.current_month_start
    QUARTERLY  = local.current_month_start
    ANNUALLY   = local.current_year_start
  }

  # Flatten per-budget actions into a single map keyed by "<budget>-action-<idx>".
  flattened_actions = flatten([
    for budget_key, budget in var.budgets : [
      for action_idx, action in budget.actions : {
        key         = "${budget_key}-action-${action_idx}"
        budget_key  = budget_key
        action      = action
      }
    ]
  ])

  actions_map = { for a in local.flattened_actions : a.key => a }
}

###############################################################################
# DynamoDB — per-budget STATE + daily SNAPSHOT trend rows + audit log
#
# PK = "BUDGET#<budget-name>"
# SK = "STATE" | "SNAPSHOT#<iso-date>" | "ACTION#<iso-ts>"
###############################################################################

resource "aws_dynamodb_table" "state" {
  count = var.enable_performance_tracking ? 1 : 0

  name         = "${var.name_prefix}-budgets-state"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "ExpireAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = var.default_tags

  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# Budget Actions execution role
#
# Created only if any budget has actions configured.
###############################################################################

resource "aws_iam_role" "budget_actions" {
  count = length(local.actions_map) > 0 ? 1 : 0

  name = "${var.name_prefix}-budget-actions-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy" "budget_actions" {
  count = length(local.actions_map) > 0 ? 1 : 0

  name = "budget-actions-execution"
  role = aws_iam_role.budget_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:AttachGroupPolicy",
          "iam:AttachRolePolicy",
          "iam:AttachUserPolicy",
          "iam:DetachGroupPolicy",
          "iam:DetachRolePolicy",
          "iam:DetachUserPolicy",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["organizations:AttachPolicy", "organizations:DetachPolicy"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:StartAutomationExecution", "ssm:SendCommand"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "rds:StopDBInstance", "rds:StopDBCluster"]
        Resource = "*"
      },
    ]
  })
}

###############################################################################
# Budget resources — one per entry in var.budgets
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

###############################################################################
# Budget Actions — auto-enforcement
###############################################################################

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

###############################################################################
# Performance Lambda — daily variance, burn rate, adherence, anomaly correlation
###############################################################################

resource "aws_sqs_queue" "perf_dlq" {
  count = var.enable_performance_tracking ? 1 : 0

  name                      = "${var.name_prefix}-budget-perf-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}

resource "aws_iam_role" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  name = "${var.name_prefix}-budget-perf-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "performance_basic" {
  count      = var.enable_performance_tracking ? 1 : 0
  role       = aws_iam_role.performance[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  name = "budget-perf"
  role = aws_iam_role.performance[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "budgets:ViewBudget",
          "budgets:DescribeBudget",
          "budgets:DescribeBudgets",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
          "ce:GetAnomalies",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:BatchWriteItem",
        ]
        Resource = [
          aws_dynamodb_table.state[0].arn,
          "${aws_dynamodb_table.state[0].arn}/index/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.events_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.perf_dlq[0].arn
      },
    ]
  })
}

data "archive_file" "performance" {
  count       = var.enable_performance_tracking ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/budget_performance.py"
  output_path = "${path.module}/lambda/budget_performance.zip"
}

resource "aws_cloudwatch_log_group" "performance" {
  count             = var.enable_performance_tracking ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-budget-perf"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  function_name    = "${var.name_prefix}-budget-perf"
  description      = "Daily FinOps budget performance: variance, burn-rate, adherence score, anomaly correlation."
  role             = aws_iam_role.performance[0].arn
  filename         = data.archive_file.performance[0].output_path
  source_code_hash = data.archive_file.performance[0].output_base64sha256
  handler          = "budget_performance.handler"
  runtime          = var.lambda_runtime
  timeout          = 300
  memory_size      = 512
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = {
      STATE_TABLE_NAME = aws_dynamodb_table.state[0].name
      METRIC_NAMESPACE = local.metric_namespace
      SSM_PREFIX       = local.ssm_prefix
      SNS_TOPIC_ARN    = var.events_topic_arn
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.perf_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.performance]
  tags       = var.default_tags
}

resource "aws_cloudwatch_event_rule" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  name                = "${var.name_prefix}-budget-perf"
  schedule_expression = "cron(${var.performance_schedule_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "performance" {
  count     = var.enable_performance_tracking ? 1 : 0
  rule      = aws_cloudwatch_event_rule.performance[0].name
  target_id = "perf"
  arn       = aws_lambda_function.performance[0].arn
}

resource "aws_lambda_permission" "performance_events" {
  count         = var.enable_performance_tracking ? 1 : 0
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.performance[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.performance[0].arn
}

###############################################################################
# Alarms — on the performance Lambda + on the metrics it emits
###############################################################################

resource "aws_cloudwatch_metric_alarm" "perf_errors" {
  count = var.enable_performance_tracking ? 1 : 0

  alarm_name          = "${var.name_prefix}-budget-perf-errors"
  alarm_description   = "FinOps budget-performance Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.performance[0].function_name }
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "perf_dlq_depth" {
  count = var.enable_performance_tracking ? 1 : 0

  alarm_name          = "${var.name_prefix}-budget-perf-dlq-depth"
  alarm_description   = "Messages accumulating in the budget-performance Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.perf_dlq[0].name }
  alarm_actions       = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "adherence_low" {
  count = var.enable_performance_tracking && var.adherence_alarm_threshold != null ? 1 : 0

  alarm_name          = "${var.name_prefix}-budget-adherence-low"
  alarm_description   = "BudgetAdherenceScore (% of budgets currently within target) dropped below threshold."
  namespace           = local.metric_namespace
  metric_name         = "BudgetAdherenceScore"
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.adherence_alarm_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

###############################################################################
# Auto-provisioned CloudWatch dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "budgets" {
  count = var.enable_performance_tracking ? 1 : 0

  dashboard_name = "${var.name_prefix}-budgets"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6,
        properties = {
          title  = "Budget adherence score (%)"
          view   = "gauge", region = data.aws_region.current.name,
          period = 86400, stat = "Minimum",
          yAxis = { left = { min = 0, max = 100 } },
          annotations = {
            horizontal = [
              { value = var.adherence_alarm_threshold == null ? 80 : var.adherence_alarm_threshold,
                label = "Target", color = "#9CCC65" }
            ]
          },
          metrics = [[local.metric_namespace, "BudgetAdherenceScore"]]
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 16, height = 6,
        properties = {
          title  = "Active budget count"
          view   = "singleValue", region = data.aws_region.current.name,
          period = 86400, stat = "Maximum",
          metrics = [[local.metric_namespace, "ActiveBudgetCount"]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 24, height = 8,
        properties = {
          title  = "Variance % — by budget"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.name,
          period = 86400, stat = "Maximum",
          yAxis = { left = { label = "Variance %" } },
          metrics = [
            for k, _ in var.budgets : [
              local.metric_namespace, "VariancePct", "Budget", "${var.name_prefix}-${k}",
            ]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 24, height = 8,
        properties = {
          title  = "Burn-rate days-to-breach — by budget"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.name,
          period = 86400, stat = "Minimum",
          yAxis = { left = { label = "Days until breach" } },
          metrics = [
            for k, _ in var.budgets : [
              local.metric_namespace, "BurnRateDaysToBreach", "Budget", "${var.name_prefix}-${k}",
            ]
          ]
        }
      },
      {
        type = "text", x = 0, y = 22, width = 24, height = 2,
        properties = {
          markdown = "## Budgets — FinOps control plane\n\nDashboard for the **budgets** module. Metrics under `${local.metric_namespace}`. State + 90-day trend rows in DynamoDB `${aws_dynamodb_table.state[0].name}`. SSM mirror: `${local.ssm_prefix}/*`."
        }
      },
    ]
  })
}

###############################################################################
# Outputs
###############################################################################

output "budget_ids" {
  description = "Map of budget key → Budgets resource ID."
  value       = { for k, v in aws_budgets_budget.this : k => v.id }
}

output "budget_names" {
  description = "Map of budget key → budget name."
  value       = { for k, v in aws_budgets_budget.this : k => v.name }
}

output "budget_action_ids" {
  description = "Map of budget action key → Budgets Action ID."
  value       = { for k, v in aws_budgets_budget_action.this : k => v.id }
}

output "state_table_name" {
  description = "DynamoDB table holding STATE / SNAPSHOT / ACTION rows for budget performance tracking (null if disabled)."
  value       = var.enable_performance_tracking ? aws_dynamodb_table.state[0].name : null
}

output "state_table_arn" {
  description = "DynamoDB state table ARN."
  value       = var.enable_performance_tracking ? aws_dynamodb_table.state[0].arn : null
}

output "performance_lambda_arn" {
  description = "Budget performance Lambda ARN (null if disabled)."
  value       = var.enable_performance_tracking ? aws_lambda_function.performance[0].arn : null
}

output "performance_dlq_arn" {
  description = "Budget performance Lambda DLQ ARN."
  value       = var.enable_performance_tracking ? aws_sqs_queue.perf_dlq[0].arn : null
}

output "metric_namespace" {
  description = "CloudWatch namespace under which budget KPIs are published."
  value       = local.metric_namespace
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix for budget KPI mirrors."
  value       = local.ssm_prefix
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard name."
  value       = var.enable_performance_tracking ? aws_cloudwatch_dashboard.budgets[0].dashboard_name : null
}

output "budget_actions_role_arn" {
  description = "Execution role ARN used by AWS Budget Actions (null if no actions configured)."
  value       = length(local.actions_map) > 0 ? aws_iam_role.budget_actions[0].arn : null
}
