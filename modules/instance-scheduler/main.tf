###############################################################################
# Instance Scheduler module
#
# A tag-driven start/stop scheduler for EC2 (and optionally RDS).
#
# Banking design principle: OPT-IN BY TAG.
#
#   Most scheduler tools are opt-out: everything stops unless you tag it.
#   That is dangerous in a bank — one untagged production database can
#   become an outage that costs more than the entire FinOps program saves
#   in a year.
#
#   This scheduler is OPT-IN. An instance is scheduled only if it carries
#   the tag <opt_in_tag_key> (default "Schedule") whose VALUE is a known
#   schedule name (e.g. "office-hours-cet"). Anything else is left alone.
#
# Schedules:
#   Defined in variable `schedules`. Each has a start_cron and stop_cron.
#   The Lambda runs on a fixed 5-minute schedule and at each tick decides
#   what to do based on the current time and each schedule's cron windows.
###############################################################################

variable "name_prefix"         { type = string }
variable "events_topic_arn"     { type = string }
variable "kms_key_arn"         { type = string }
variable "log_retention_days"  { type = number }
variable "opt_in_tag_key"      { type = string }
variable "schedules" {
  type = map(object({
    start_cron = string
    stop_cron  = string
  }))
}
variable "lambda_runtime"     { type = string }
variable "default_tags"       { type = map(string) }

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

###############################################################################
# IAM
###############################################################################

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-role"
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

resource "aws_iam_role_policy_attachment" "scheduler_basic" {
  role       = aws_iam_role.scheduler.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "scheduler" {
  name = "scheduler"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeTags",
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
# Dead-letter queue for failed scheduler invocations.
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-scheduler-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}

###############################################################################
# Lambda
###############################################################################

data "archive_file" "scheduler" {
  type        = "zip"
  source_file = "${path.module}/lambda/scheduler.py"
  output_path = "${path.module}/lambda/scheduler.zip"
}

resource "aws_cloudwatch_log_group" "scheduler" {
  name              = "/aws/lambda/${var.name_prefix}-scheduler"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "scheduler" {
  function_name    = "${var.name_prefix}-scheduler"
  description      = "Tag-driven EC2 start/stop scheduler (opt-in by tag)."
  role             = aws_iam_role.scheduler.arn
  filename         = data.archive_file.scheduler.output_path
  source_code_hash = data.archive_file.scheduler.output_base64sha256
  handler          = "scheduler.handler"
  runtime          = var.lambda_runtime
  timeout          = 300
  memory_size      = 256
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = {
      OPT_IN_TAG_KEY = var.opt_in_tag_key
      SCHEDULES_JSON = jsonencode(var.schedules)
      SNS_TOPIC_ARN  = var.events_topic_arn
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.scheduler]
  tags       = var.default_tags
}

###############################################################################
# Trigger every 5 minutes
###############################################################################

resource "aws_cloudwatch_event_rule" "scheduler" {
  name                = "${var.name_prefix}-scheduler-tick"
  schedule_expression = "rate(5 minutes)"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "scheduler" {
  rule      = aws_cloudwatch_event_rule.scheduler.name
  target_id = "scheduler"
  arn       = aws_lambda_function.scheduler.arn
}

resource "aws_lambda_permission" "scheduler_events" {
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduler.arn
}

###############################################################################
# CloudWatch alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-scheduler-errors"
  alarm_description   = "FinOps instance-scheduler Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.scheduler.function_name
  }

  alarm_actions = [var.events_topic_arn]
  ok_actions    = [var.events_topic_arn]
  tags          = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_dlq_depth" {
  alarm_name          = "${var.name_prefix}-scheduler-dlq-depth"
  alarm_description   = "Messages accumulating in the instance-scheduler Lambda DLQ."
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
  value = aws_lambda_function.scheduler.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}
