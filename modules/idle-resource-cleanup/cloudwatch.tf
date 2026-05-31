###############################################################################
# CloudWatch — per-Lambda self-health alarms + aggregate waste alarm + dashboard
#
# Three layers:
#   1. Per-Lambda Errors + DLQ-depth alarm pair (one set per enabled resource type)
#   2. total_waste metric-math alarm — fires when SUM(MonthlyWasteUsd) across
#      all six resource-type dimensions exceeds the configured threshold
#   3. Auto-provisioned dashboard: monthly-waste / per-run savings / found-count
#      / Lambda errors / DLQ depth — one widget per enabled resource type
###############################################################################

# ---------------------------------------------------------------------------
# Per-Lambda Errors + DLQ depth
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.enabled_types

  alarm_name          = "${var.name_prefix}-idle-${each.key}-errors"
  alarm_description   = "FinOps idle-${each.key} Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this[each.key].function_name
  }

  alarm_actions = [var.events_topic_arn]
  ok_actions    = [var.events_topic_arn]
  tags          = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_dlq_depth" {
  for_each = local.enabled_types

  alarm_name          = "${var.name_prefix}-idle-${each.key}-dlq-depth"
  alarm_description   = "Messages accumulating in the idle-${each.key} Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  alarm_actions = [var.events_topic_arn]
  tags          = var.default_tags
}

# ---------------------------------------------------------------------------
# Aggregate waste alarm — SUM(MonthlyWasteUsd) across all dimensions
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "total_waste" {
  count = var.total_waste_alarm_threshold_usd == null ? 0 : 1

  alarm_name          = "${var.name_prefix}-idle-total-waste"
  alarm_description   = "Total identified monthly waste across all idle-resource scans exceeded threshold — investigate the digest."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.total_waste_alarm_threshold_usd
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]

  metric_query {
    id          = "total"
    expression  = "SUM(METRICS())"
    label       = "Total MonthlyWasteUsd"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.enabled_types
    content {
      id = "m_${metric_query.key}"
      metric {
        namespace   = local.metric_namespace
        metric_name = "MonthlyWasteUsd"
        period      = 86400
        stat        = "Maximum"
        dimensions = {
          ResourceType = local.resource_type_label[metric_query.key]
        }
      }
    }
  }

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Auto-provisioned dashboard — single pane of glass for the FinOps lead
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "idle_cleanup" {
  dashboard_name = "${var.name_prefix}-idle-cleanup"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Monthly waste — by resource type"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "MonthlyWasteUsd", "ResourceType",
              local.resource_type_label[k],
            ]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Per-run savings ($/run)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 604800, stat = "Sum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "RunSavingsUsd", "ResourceType",
              local.resource_type_label[k],
            ]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Found count over time — by resource type"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "FoundCount", "ResourceType",
              local.resource_type_label[k],
            ]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Cleanup Lambda errors (any > 0 is a problem)"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 300, stat = "Sum",
          metrics = [
            for k, _ in local.enabled_types : [
              "AWS/Lambda", "Errors", "FunctionName", "${var.name_prefix}-idle-${k}",
            ]
          ]
        }
      },
      {
        type = "text", x = 0, y = 12, width = 24, height = 2,
        properties = {
          markdown = "## Idle resource cleanup — FinOps control plane\n\nDashboard for the **idle-resource-cleanup** module. Each tile reads from CloudWatch metric namespace `${local.metric_namespace}`. The DynamoDB table `${aws_dynamodb_table.findings.name}` carries the per-resource lifecycle state (new / aging / snoozed / excepted / deleted) and the append-only audit log (`ACTION#<timestamp>` rows)."
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 24, height = 4,
        properties = {
          title  = "DLQ depth (any non-zero means failed invocations)"
          view   = "singleValue", stacked = false,
          region = data.aws_region.current.region,
          period = 300, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              "AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName",
              "${var.name_prefix}-idle-${k}-dlq",
            ]
          ]
        }
      },
    ]
  })
}
