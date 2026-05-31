###############################################################################
# CloudWatch — Lambda self-health + financial-gap alarm
###############################################################################

resource "aws_cloudwatch_metric_alarm" "untagged_cost_lambda_errors" {
  count = local.deploy_untagged_report ? 1 : 0

  alarm_name          = "${var.name_prefix}-untagged-cost-errors"
  alarm_description   = "FinOps untagged-cost report Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.untagged_cost[0].function_name }
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "untagged_cost_dlq_depth" {
  count = local.deploy_untagged_report ? 1 : 0

  alarm_name          = "${var.name_prefix}-untagged-cost-dlq-depth"
  alarm_description   = "Messages accumulating in the untagged-cost report Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.untagged_cost_dlq[0].name }
  alarm_actions       = [var.events_topic_arn]
  tags                = var.default_tags
}

# ---------------------------------------------------------------------------
# Financial-gap alarm — fires when total mandatory-tag-gap spend exceeds the
# caller's ceiling. Period aligned to the weekly emission cadence.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "untagged_cost_excess" {
  count = local.deploy_untagged_report && var.untagged_cost_alarm_threshold_usd != null ? 1 : 0

  alarm_name        = "${var.name_prefix}-untagged-cost-excess"
  alarm_description = "Total cost of resources missing mandatory tags exceeds the configured ceiling — tag-discipline regression."
  namespace         = local.metric_namespace
  metric_name       = "TotalUntaggedCostUsd"
  statistic         = "Maximum"
  # Metric is emitted weekly; align the alarm period so missing-data flicker
  # doesn't bounce between OK and INSUFFICIENT_DATA mid-week.
  period              = 604800
  evaluation_periods  = 1
  threshold           = var.untagged_cost_alarm_threshold_usd
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}
