###############################################################################
# CloudWatch — Lambda self-health, KPI-threshold alarms, dashboard
#
# Three classes of alarm:
#   1. Performance Lambda errors + DLQ depth        (Lambda self-health)
#   2. BudgetAdherenceScore < threshold              (fleet-wide KPI)
#   3. burn_rate_low                                 (metric-math alarm over
#      every budget's BurnRateDaysToBreach metric — fires when ANY drops
#      below the configured days)
#
# Plus an auto-provisioned dashboard with gauge + per-budget time-series.
###############################################################################

# ---------------------------------------------------------------------------
# Lambda self-health
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Fleet adherence
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Burn-rate alarm — metric-math over every budget's BurnRateDaysToBreach.
#
# Each budget contributes a metric query keyed `m0..mN`. The synthesised
# `min_all` query takes the MIN across all of them and is the only
# `return_data = true` query. Fires when the minimum drops below the
# configured days-to-breach threshold.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "burn_rate_low" {
  count = (
    var.enable_performance_tracking
    && length(var.budgets) > 0
    && var.burn_rate_alarm_days_to_breach != null
  ) ? 1 : 0

  alarm_name          = "${var.name_prefix}-budget-burn-rate-low"
  alarm_description   = "Any budget's projected days-to-breach dropped below threshold — at the current spend rate, a budget breaches sooner than var.burn_rate_alarm_days_to_breach."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = var.burn_rate_alarm_days_to_breach
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags

  dynamic "metric_query" {
    for_each = { for i, k in keys(var.budgets) : k => "m${i}" }
    content {
      id          = metric_query.value
      return_data = false
      metric {
        namespace   = local.metric_namespace
        metric_name = "BurnRateDaysToBreach"
        period      = 86400
        stat        = "Minimum"
        dimensions  = { Budget = "${var.name_prefix}-${metric_query.key}" }
      }
    }
  }

  metric_query {
    id          = "min_all"
    return_data = true
    label       = "Minimum days-to-breach across all budgets"
    expression  = "MIN([${join(",", [for i in range(length(var.budgets)) : "m${i}"])}])"
  }
}

# ---------------------------------------------------------------------------
# Auto-provisioned dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "budgets" {
  count = var.enable_performance_tracking ? 1 : 0

  dashboard_name = "${var.name_prefix}-budgets"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6,
        properties = {
          title  = "Budget adherence score (%)"
          view   = "gauge", region = data.aws_region.current.region,
          period = 86400, stat = "Minimum",
          yAxis  = { left = { min = 0, max = 100 } },
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
          title   = "Active budget count"
          view    = "singleValue", region = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [[local.metric_namespace, "ActiveBudgetCount"]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 24, height = 8,
        properties = {
          title  = "Variance % — by budget"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          yAxis  = { left = { label = "Variance %" } },
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
          region = data.aws_region.current.region,
          period = 86400, stat = "Minimum",
          yAxis  = { left = { label = "Days until breach" } },
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
