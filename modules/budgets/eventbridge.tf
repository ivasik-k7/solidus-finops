###############################################################################
# EventBridge — daily performance-Lambda trigger
###############################################################################

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
