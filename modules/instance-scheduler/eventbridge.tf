###############################################################################
# EventBridge — schedule triggers for both Lambdas
###############################################################################

# ---------------------------------------------------------------------------
# Scheduler tick
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "scheduler" {
  name                = "${var.name_prefix}-scheduler-tick"
  description         = "Tick fires the scheduler Lambda; default rate(5 minutes)"
  schedule_expression = var.tick_schedule

  tags = var.default_tags
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

# ---------------------------------------------------------------------------
# Discovery weekly run
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "discovery" {
  count = var.enable_discovery ? 1 : 0

  name                = "${var.name_prefix}-scheduler-discovery"
  description         = "Weekly trigger for the auto-discovery Lambda"
  schedule_expression = "cron(${var.discovery_schedule_cron})"

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "discovery" {
  count = var.enable_discovery ? 1 : 0

  rule      = aws_cloudwatch_event_rule.discovery[0].name
  target_id = "discovery"
  arn       = aws_lambda_function.discovery[0].arn
}

resource "aws_lambda_permission" "discovery_events" {
  count = var.enable_discovery ? 1 : 0

  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discovery[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.discovery[0].arn
}
