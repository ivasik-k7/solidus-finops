###############################################################################
# CloudWatch — dispatcher Lambda self-health alarms.
#
# Note: these alarms intentionally do NOT publish back to the alerts SNS
# topic — the dispatcher consumes that topic, so a failure-republish loop
# would amplify a problem rather than alert on it. Subscribers can discover
# the alarms via `aws cloudwatch describe-alarms` or watch the metrics
# directly.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "dispatcher_errors" {
  count = local.any_dispatch_channels ? 1 : 0

  alarm_name          = "${var.name_prefix}-dispatcher-errors"
  alarm_description   = "Event dispatcher Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.dispatcher[0].function_name }

  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "dispatcher_dlq_depth" {
  count = local.any_dispatch_channels ? 1 : 0

  alarm_name          = "${var.name_prefix}-dispatcher-dlq-depth"
  alarm_description   = "Messages accumulating in the event dispatcher DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.dispatcher_dlq[0].name }

  tags = var.default_tags
}
