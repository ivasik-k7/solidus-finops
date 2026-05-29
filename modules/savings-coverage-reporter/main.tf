###############################################################################
# Savings Coverage Reporter module
#
# A weekly Lambda that queries Cost Explorer for RI and Savings Plan
# coverage and utilization. Publishes a structured report to SNS.
#
# Why this matters:
#   - Coverage too LOW = leaving discount on the table.
#   - Utilization too LOW = paying for unused commitments. A 3-year RI at
#     50% utilization is worse than on-demand.
#
# The report includes:
#   - Coverage % of eligible spend, last 30 days, by RI and SP separately.
#   - Utilization % of active commitments.
#   - Delta vs. target (var.target_coverage_pct).
#   - List of underutilized commitments (top 10).
###############################################################################

variable "name_prefix"          { type = string }
variable "events_topic_arn"      { type = string }
variable "kms_key_arn"          { type = string }
variable "log_retention_days"   { type = number }
variable "report_cron"          { type = string }
variable "target_coverage_pct"  { type = number }
variable "lambda_runtime"      { type = string }
variable "default_tags"        { type = map(string) }

data "aws_partition" "current" {}

###############################################################################
# IAM
###############################################################################

resource "aws_iam_role" "coverage" {
  name = "${var.name_prefix}-coverage-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "coverage_basic" {
  role       = aws_iam_role.coverage.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "coverage" {
  name = "coverage"
  role = aws_iam_role.coverage.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ce:GetReservationCoverage",
          "ce:GetReservationUtilization",
          "ce:GetSavingsPlansCoverage",
          "ce:GetSavingsPlansUtilization",
          "ce:GetSavingsPlansUtilizationDetails",
        ]
        Resource = "*"
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

###############################################################################
# Dead-letter queue for failed coverage-reporter invocations.
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-coverage-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}

###############################################################################
# Lambda
###############################################################################

data "archive_file" "coverage" {
  type        = "zip"
  source_file = "${path.module}/lambda/coverage_report.py"
  output_path = "${path.module}/lambda/coverage_report.zip"
}

resource "aws_cloudwatch_log_group" "coverage" {
  name              = "/aws/lambda/${var.name_prefix}-coverage-report"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "coverage" {
  function_name    = "${var.name_prefix}-coverage-report"
  description      = "Weekly RI and Savings Plan coverage / utilization report."
  role             = aws_iam_role.coverage.arn
  filename         = data.archive_file.coverage.output_path
  source_code_hash = data.archive_file.coverage.output_base64sha256
  handler          = "coverage_report.handler"
  runtime          = var.lambda_runtime
  timeout          = 120
  memory_size      = 256
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = {
      SNS_TOPIC_ARN       = var.events_topic_arn
      TARGET_COVERAGE_PCT = tostring(var.target_coverage_pct)
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.coverage]
  tags       = var.default_tags
}

resource "aws_cloudwatch_event_rule" "coverage" {
  name                = "${var.name_prefix}-coverage-weekly"
  schedule_expression = "cron(${var.report_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "coverage" {
  rule      = aws_cloudwatch_event_rule.coverage.name
  target_id = "coverage"
  arn       = aws_lambda_function.coverage.arn
}

resource "aws_lambda_permission" "coverage_events" {
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.coverage.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.coverage.arn
}

###############################################################################
# CloudWatch alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-coverage-errors"
  alarm_description   = "FinOps savings-coverage-reporter Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.coverage.function_name
  }

  alarm_actions = [var.events_topic_arn]
  ok_actions    = [var.events_topic_arn]
  tags          = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_dlq_depth" {
  alarm_name          = "${var.name_prefix}-coverage-dlq-depth"
  alarm_description   = "Messages accumulating in the coverage-reporter Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_actions = [var.events_topic_arn]
  tags          = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "lambda_arn" {
  value = aws_lambda_function.coverage.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}
