###############################################################################
# CloudWatch — Lambda-self alarms + KPI-threshold alarms + base dashboard
#
# Note on the dashboard: Terraform creates an INITIAL skeleton. The aggregator
# Lambda re-PUTs the dashboard on every run, layering on:
#   - per-tag-value widgets (when tag_value_dashboard_tag is set)
#   - custom-KPI widgets (one per var.custom_kpis entry)
#   - moving-average + WoW-drift trend widgets (when trend_metrics_enabled)
#
# Terraform owning the initial put means the dashboard is non-empty from
# day 1, even before the first Lambda invocation.
###############################################################################

# ---------------------------------------------------------------------------
# Lambda-self alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "aggregator_errors" {
  alarm_name          = "${var.name_prefix}-kpi-aggregator-errors"
  alarm_description   = "FinOps KPI aggregator Lambda errors (Sum over 5 min > 0)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.aggregator.function_name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "aggregator_dlq_depth" {
  alarm_name          = "${var.name_prefix}-kpi-aggregator-dlq-depth"
  alarm_description   = "Messages accumulating in the KPI aggregator DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Built-in absolute-threshold alarms — gated by both `enabled` AND `threshold != null`
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "allocation_coverage_low" {
  count = (var.builtin_kpis_enabled.allocation_coverage && var.alarm_thresholds.allocation_coverage_min_pct != null) ? 1 : 0

  alarm_name          = "${var.name_prefix}-kpi-allocation-coverage-low"
  alarm_description   = "Allocation coverage % is below target — tagging discipline degraded."
  namespace           = local.metric_namespace
  metric_name         = "AllocationCoveragePct"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.allocation_coverage_min_pct
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "commitment_coverage_low" {
  count = (var.builtin_kpis_enabled.commitment_coverage && var.alarm_thresholds.commitment_coverage_min_pct != null) ? 1 : 0

  alarm_name          = "${var.name_prefix}-kpi-commitment-coverage-low"
  alarm_description   = "RI+SP commitment coverage % is below target — review purchase recommendations."
  namespace           = local.metric_namespace
  metric_name         = "CommitmentCoveragePct"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.commitment_coverage_min_pct
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "commitment_utilization_low" {
  count = (var.builtin_kpis_enabled.commitment_utilization && var.alarm_thresholds.commitment_utilization_min_pct != null) ? 1 : 0

  alarm_name          = "${var.name_prefix}-kpi-commitment-utilization-low"
  alarm_description   = "RI+SP utilization % is below target — paying for unused commitments."
  namespace           = local.metric_namespace
  metric_name         = "CommitmentUtilizationPct"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.commitment_utilization_min_pct
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "forecast_drift_high" {
  count = (var.builtin_kpis_enabled.forecast_drift && var.alarm_thresholds.forecast_accuracy_max_drift_pct != null) ? 1 : 0

  alarm_name          = "${var.name_prefix}-kpi-forecast-drift-high"
  alarm_description   = "Actual cost is drifting from forecast by more than the configured threshold."
  namespace           = local.metric_namespace
  metric_name         = "ForecastAbsDriftPct"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.forecast_accuracy_max_drift_pct
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Week-over-week drift alarm — fires when AllocationCoverage drops
# more than `wow_drift_alarm_threshold_pct` % WoW. Reads the derived metric
# emitted by the aggregator when trend_metrics_enabled = true.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "allocation_coverage_wow_drift" {
  count = (var.builtin_kpis_enabled.allocation_coverage && var.trend_metrics_enabled && var.wow_drift_alarm_threshold_pct != null) ? 1 : 0

  alarm_name          = "${var.name_prefix}-kpi-allocation-coverage-wow-drift"
  alarm_description   = "Week-over-week drop in AllocationCoveragePct exceeds threshold — investigate recent tagging changes."
  namespace           = local.metric_namespace
  metric_name         = "AllocationCoveragePct_WoWDriftPct"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = -var.wow_drift_alarm_threshold_pct
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Custom-KPI alarms — one per custom_kpis entry that declares an `alarm`
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "custom_kpi" {
  for_each = { for k, v in var.custom_kpis : k => v if v.alarm != null }

  alarm_name          = "${var.name_prefix}-kpi-custom-${each.key}"
  alarm_description   = "Custom KPI '${each.key}' breached threshold."
  namespace           = local.metric_namespace
  metric_name         = "Custom_${each.key}"
  statistic           = "Average"
  period              = 86400
  evaluation_periods  = 1
  threshold           = each.value.alarm.threshold
  comparison_operator = each.value.alarm.comparison
  treat_missing_data  = "ignore"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Base dashboard — replaced/extended by the aggregator Lambda on every run.
#
# Terraform owns the initial skeleton so users see SOMETHING on day 1
# (before the first Lambda run); the Lambda then re-PUTs with the full
# layout including per-tag-value widgets, trend lines, and custom KPIs.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "kpis" {
  dashboard_name = "${var.name_prefix}-kpis"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2,
        properties = {
          markdown = "## FinOps KPIs — ${var.name_prefix}\n\nNamespace `${local.metric_namespace}`. Aggregator Lambda `${var.name_prefix}-kpi-aggregator` runs daily on `cron(${var.aggregator_cron})`. Widgets below are the initial skeleton; the Lambda extends the dashboard on each run with trend lines, per-tag-value panels, and any custom KPIs you've defined."
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6,
        properties = {
          title  = "Allocation coverage %"
          view   = "singleValue", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Average",
          metrics = [
            [local.metric_namespace, "AllocationCoveragePct"],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6,
        properties = {
          title  = "Commitment coverage %"
          view   = "singleValue", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Average",
          metrics = [
            [local.metric_namespace, "CommitmentCoveragePct"],
            [".", "CommitmentUtilizationPct"],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6,
        properties = {
          title  = "Forecast drift % + Anomaly impact USD"
          view   = "singleValue", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Average",
          metrics = [
            [local.metric_namespace, "ForecastAbsDriftPct"],
            [".", "AnomalyImpactUsdMtd"],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 24, height = 6,
        properties = {
          title  = "Spend by service — top 10 (this month)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 86400, stat = "Sum",
          metrics = [
            [{ "expression" : "SEARCH('Namespace=\"${local.metric_namespace}\" MetricName=\"SpendByServiceUsd\"', 'Sum')", "id" : "e1" }],
          ]
        }
      },
    ]
  })

  # Caveat: Terraform and the Lambda both touch this resource. Terraform
  # owns the initial body; the Lambda re-PUTs on every run. The Lambda's
  # writes will show as drift on the next `terraform plan` — that's
  # expected. Re-applying restores the skeleton; the next Lambda run
  # restores the full layout. Use `ignore_changes = [dashboard_body]`
  # if drift noise bothers your CI.
  lifecycle {
    ignore_changes = [dashboard_body]
  }
}
