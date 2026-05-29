###############################################################################
# FinOps Metrics module
#
# Produces a standard set of named FinOps KPIs from the data the rest of the
# framework already collects (CUR, Cost Categories, Cost Explorer, Cost Anomaly
# Detection). The same KPI values are emitted three ways so any consumer can
# read them:
#
#   1. Athena named queries — for BI tools (QuickSight, Power BI, Looker, ...)
#   2. CloudWatch custom metrics under namespace "FinOps/KPIs" — for alarms
#   3. SSM Parameter Store under /<name_prefix>/kpis/* — for cross-workspace
#      Terraform consumption
#
# The aggregator Lambda runs once per day, queries the upstream sources,
# and writes the three sinks above.
#
# KPIs emitted (FinOps Foundation aligned):
#   - allocation_coverage_pct       : tagged spend / total spend
#   - commitment_coverage_pct       : RI+SP-covered spend / eligible compute
#   - commitment_utilization_pct    : used / purchased RI+SP capacity
#   - anomaly_impact_usd_mtd        : confirmed anomaly impact, month-to-date
#   - idle_resource_value_usd       : value of resources flagged by idle-cleanup
#   - unit_cost_<category>_<value>  : cost per allocation unit, per cost category
#   - forecast_accuracy_pct         : abs(1 - actual/forecast) × 100
###############################################################################

variable "name_prefix"          { type = string }
variable "events_topic_arn"     { type = string }
variable "kms_key_arn"          { type = string }
variable "log_retention_days"   { type = number }
variable "lambda_runtime"       { type = string }
variable "default_tags"         { type = map(string) }

variable "athena_workgroup_name" {
  description = "Athena workgroup the named queries are registered against."
  type        = string
}

variable "athena_database_name" {
  description = "Glue database holding the CUR table."
  type        = string
}

variable "cur_table_name" {
  description = "Glue table name for the CUR 2.0 export. Convention: <athena_database_name>.<cur_table_name>."
  type        = string
  default     = "cur2"
}

variable "allocation_tag_keys" {
  description = "Tag keys considered 'allocation tags'. A line of CUR is counted as allocated only if it carries all of these tags. Typically [CostCenter, BusinessUnit, Application]."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

variable "aggregator_cron" {
  description = "EventBridge cron expression (UTC, six-field) for the KPI aggregator Lambda."
  type        = string
  default     = "0 7 * * ? *" # 07:00 UTC daily
}

variable "alarm_thresholds" {
  description = <<-EOT
    Per-KPI alarm thresholds. Set a key to null to skip the alarm.
      - allocation_coverage_min_pct : alarm if below this %
      - commitment_coverage_min_pct : alarm if below this %
      - commitment_utilization_min_pct : alarm if below this %
      - forecast_accuracy_max_drift_pct : alarm if drift exceeds this %
  EOT
  type = object({
    allocation_coverage_min_pct       = optional(number, 80)
    commitment_coverage_min_pct       = optional(number, 70)
    commitment_utilization_min_pct    = optional(number, 80)
    forecast_accuracy_max_drift_pct   = optional(number, 15)
  })
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  metric_namespace = "FinOps/KPIs"
  ssm_prefix       = "/${var.name_prefix}/kpis"

  cur_full_table   = "${var.athena_database_name}.${var.cur_table_name}"

  # Build a CUR predicate that requires every allocation tag to be present.
  # CUR 2.0 exposes tags as resource_tags['user_<TagKey>'] columns.
  allocation_tag_predicate = join(" AND ", [
    for k in var.allocation_tag_keys :
    "resource_tags['user_${k}'] IS NOT NULL AND resource_tags['user_${k}'] != ''"
  ])
}

###############################################################################
# Athena named queries — one per KPI / view.
#
# These are queryable directly from any BI tool against the framework's
# workgroup. They are also the source of truth the aggregator Lambda calls.
###############################################################################

resource "aws_athena_named_query" "allocation_coverage" {
  name        = "${var.name_prefix}-kpi-allocation-coverage"
  description = "FinOps KPI: % of unblended cost carrying all allocation tags, current month."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      ROUND(100.0 * SUM(CASE WHEN ${local.allocation_tag_predicate} THEN line_item_unblended_cost ELSE 0 END)
                  / NULLIF(SUM(line_item_unblended_cost), 0), 2) AS allocation_coverage_pct,
      SUM(line_item_unblended_cost) AS total_cost_usd,
      SUM(CASE WHEN ${local.allocation_tag_predicate} THEN line_item_unblended_cost ELSE 0 END) AS allocated_cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
  SQL
}

resource "aws_athena_named_query" "spend_by_service" {
  name        = "${var.name_prefix}-kpi-spend-by-service"
  description = "FinOps KPI: unblended cost by AWS service, current month — sorted descending."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      product_servicecode AS service,
      SUM(line_item_unblended_cost) AS cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
    GROUP BY product_servicecode
    ORDER BY cost_usd DESC
  SQL
}

resource "aws_athena_named_query" "unit_cost_by_business_unit" {
  name        = "${var.name_prefix}-kpi-unit-cost-by-business-unit"
  description = "FinOps KPI: cost per BusinessUnit tag value, current month."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      COALESCE(resource_tags['user_BusinessUnit'], 'unallocated') AS business_unit,
      SUM(line_item_unblended_cost) AS cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
    GROUP BY COALESCE(resource_tags['user_BusinessUnit'], 'unallocated')
    ORDER BY cost_usd DESC
  SQL
}

resource "aws_athena_named_query" "month_over_month_growth" {
  name        = "${var.name_prefix}-kpi-month-over-month-growth"
  description = "FinOps KPI: month-over-month % change in unblended cost, by service."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    WITH this_month AS (
      SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost
      FROM ${local.cur_full_table}
      WHERE billing_period = date_format(current_date, '%Y-%m')
      GROUP BY product_servicecode
    ),
    last_month AS (
      SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost
      FROM ${local.cur_full_table}
      WHERE billing_period = date_format(current_date - interval '1' month, '%Y-%m')
      GROUP BY product_servicecode
    )
    SELECT
      COALESCE(t.service, l.service) AS service,
      COALESCE(t.cost, 0) AS this_month_cost,
      COALESCE(l.cost, 0) AS last_month_cost,
      ROUND(100.0 * (COALESCE(t.cost, 0) - COALESCE(l.cost, 0)) / NULLIF(l.cost, 0), 2) AS pct_change
    FROM this_month t
    FULL OUTER JOIN last_month l ON t.service = l.service
    ORDER BY ABS(COALESCE(t.cost, 0) - COALESCE(l.cost, 0)) DESC
  SQL
}

###############################################################################
# KPI aggregator Lambda — runs daily.
###############################################################################

resource "aws_iam_role" "aggregator" {
  name = "${var.name_prefix}-kpi-aggregator-role"
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

resource "aws_iam_role_policy_attachment" "aggregator_basic" {
  role       = aws_iam_role.aggregator.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aggregator" {
  name = "kpi-aggregator"
  role = aws_iam_role.aggregator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetPartitions",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
        ]
        Resource = "*"
      },
      # KMS perms so Athena can decrypt CUR data and encrypt query results
      # written to the KMS-encrypted athena-results bucket.
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = var.kms_key_arn
      },
      {
        Effect = "Allow"
        Action = [
          "ce:GetReservationCoverage",
          "ce:GetReservationUtilization",
          "ce:GetSavingsPlansCoverage",
          "ce:GetSavingsPlansUtilization",
          "ce:GetAnomalies",
          "ce:GetCostForecast",
          "ce:GetCostAndUsage",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
        ]
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
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}

data "archive_file" "aggregator" {
  type        = "zip"
  source_file = "${path.module}/lambda/kpi_aggregator.py"
  output_path = "${path.module}/lambda/kpi_aggregator.zip"
}

resource "aws_cloudwatch_log_group" "aggregator" {
  name              = "/aws/lambda/${var.name_prefix}-kpi-aggregator"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-kpi-aggregator-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}

resource "aws_lambda_function" "aggregator" {
  function_name    = "${var.name_prefix}-kpi-aggregator"
  description      = "Daily FinOps KPI aggregator → CloudWatch metrics + SSM parameters."
  role             = aws_iam_role.aggregator.arn
  filename         = data.archive_file.aggregator.output_path
  source_code_hash = data.archive_file.aggregator.output_base64sha256
  handler          = "kpi_aggregator.handler"
  runtime          = var.lambda_runtime
  timeout          = 300
  memory_size      = 512
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = {
      METRIC_NAMESPACE       = local.metric_namespace
      SSM_PREFIX             = local.ssm_prefix
      ATHENA_WORKGROUP       = var.athena_workgroup_name
      ATHENA_DATABASE        = var.athena_database_name
      CUR_TABLE              = var.cur_table_name
      ALLOCATION_TAG_KEYS    = jsonencode(var.allocation_tag_keys)
      SNS_TOPIC_ARN          = var.events_topic_arn
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.aggregator]
  tags       = var.default_tags
}

resource "aws_cloudwatch_event_rule" "aggregator" {
  name                = "${var.name_prefix}-kpi-aggregator"
  schedule_expression = "cron(${var.aggregator_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "aggregator" {
  rule      = aws_cloudwatch_event_rule.aggregator.name
  target_id = "aggregator"
  arn       = aws_lambda_function.aggregator.arn
}

resource "aws_lambda_permission" "aggregator_events" {
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.aggregator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.aggregator.arn
}

###############################################################################
# CloudWatch alarms on the aggregator Lambda itself
###############################################################################

resource "aws_cloudwatch_metric_alarm" "aggregator_errors" {
  alarm_name          = "${var.name_prefix}-kpi-aggregator-errors"
  alarm_description   = "FinOps KPI aggregator Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.aggregator.function_name }
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
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
  alarm_actions       = [var.events_topic_arn]
  tags                = var.default_tags
}

###############################################################################
# Optional KPI-threshold alarms — fire when a KPI itself crosses a bar.
#
# Each alarm watches the corresponding custom metric in the FinOps/KPIs
# namespace. The aggregator Lambda emits these metrics; if you set a
# threshold variable to null, that alarm is skipped.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "allocation_coverage_low" {
  count = var.alarm_thresholds.allocation_coverage_min_pct == null ? 0 : 1

  alarm_name          = "${var.name_prefix}-kpi-allocation-coverage-low"
  alarm_description   = "Allocation coverage % is below target — tagging discipline degraded."
  namespace           = local.metric_namespace
  metric_name         = "AllocationCoveragePct"
  statistic           = "Average"
  period              = 86400 # 1 day
  evaluation_periods  = 1
  threshold           = var.alarm_thresholds.allocation_coverage_min_pct
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "commitment_coverage_low" {
  count = var.alarm_thresholds.commitment_coverage_min_pct == null ? 0 : 1

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
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "commitment_utilization_low" {
  count = var.alarm_thresholds.commitment_utilization_min_pct == null ? 0 : 1

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
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "forecast_drift_high" {
  count = var.alarm_thresholds.forecast_accuracy_max_drift_pct == null ? 0 : 1

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
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "aggregator_lambda_arn" {
  value = aws_lambda_function.aggregator.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "metric_namespace" {
  description = "CloudWatch namespace under which KPIs are published."
  value       = local.metric_namespace
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix under which KPIs are mirrored."
  value       = local.ssm_prefix
}

output "named_query_ids" {
  description = "Athena named query IDs registered by this module."
  value = {
    allocation_coverage         = aws_athena_named_query.allocation_coverage.id
    spend_by_service            = aws_athena_named_query.spend_by_service.id
    unit_cost_by_business_unit  = aws_athena_named_query.unit_cost_by_business_unit.id
    month_over_month_growth     = aws_athena_named_query.month_over_month_growth.id
  }
}
