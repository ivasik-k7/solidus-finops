###############################################################################
# CloudWatch — alarms + auto-provisioned dashboard
###############################################################################

# ---------------------------------------------------------------------------
# Alarms — both Lambdas
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "scheduler_errors" {
  alarm_name          = "${var.name_prefix}-scheduler-errors"
  alarm_description   = "Scheduler Lambda errors (Sum over 5 min > 0)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.scheduler.function_name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "scheduler_dlq_depth" {
  alarm_name          = "${var.name_prefix}-scheduler-dlq-depth"
  alarm_description   = "Messages accumulating in the scheduler DLQ — failed invocations."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.scheduler_dlq.name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "discovery_errors" {
  count = var.enable_discovery ? 1 : 0

  alarm_name          = "${var.name_prefix}-scheduler-discovery-errors"
  alarm_description   = "Auto-discovery Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.discovery[0].function_name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Dashboard — savings curve, activity, errors, DLQ depth
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "scheduler" {
  dashboard_name = "${var.name_prefix}-scheduler"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Daily action throughput (started + stopped)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 86400, stat = "Sum",
          metrics = [
            [local.metric_namespace, "ActionStarted"],
            [local.metric_namespace, "ActionStopped"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Actions per tick (started / stopped / skipped)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 300, stat = "Sum",
          metrics = [
            [local.metric_namespace, "ActionStarted"],
            [local.metric_namespace, "ActionStopped"],
            [local.metric_namespace, "ActionSkippedOverride"],
            [local.metric_namespace, "ActionSkippedCeiling"],
            [local.metric_namespace, "ActionFailed"],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Scheduled resource count (currently managed)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 300, stat = "Maximum",
          metrics = [
            [local.metric_namespace, "ManagedResourceCount", "ResourceType", "EC2"],
            [local.metric_namespace, "ManagedResourceCount", "ResourceType", "RDSInstance"],
            [local.metric_namespace, "ManagedResourceCount", "ResourceType", "RDSCluster"],
            [local.metric_namespace, "ManagedResourceCount", "ResourceType", "ASG"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Scheduler Lambda errors + DLQ depth"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 300, stat = "Maximum",
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.scheduler.function_name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.scheduler_dlq.name],
          ]
        }
      },
      {
        type = "text", x = 0, y = 12, width = 24, height = 2,
        properties = {
          markdown = "## Instance scheduler — FinOps execution layer\n\nCloudWatch namespace: `${local.metric_namespace}` — DynamoDB STATE + ACTION rows in `${aws_dynamodb_table.state.name}` — DLQ: `${aws_sqs_queue.scheduler_dlq.name}` — Regions scanned: `${join(", ", local.effective_regions)}`\n\n**Dollar-value cost reporting is owned by your analytics tool** (Cloudability / CUR-backed dashboards). This module emits action counts; the analytics layer joins those to actual paid prices."
        }
      },
    ]
  })
}
