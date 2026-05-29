###############################################################################
# EventBridge — daily aggregator trigger
###############################################################################

resource "aws_cloudwatch_event_rule" "aggregator" {
  name                = "${var.name_prefix}-kpi-aggregator"
  description         = "Daily trigger for the FinOps KPI aggregator."
  schedule_expression = "cron(${var.aggregator_cron})"

  tags = var.default_tags
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
