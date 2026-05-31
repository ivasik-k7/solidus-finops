###############################################################################
# EventBridge — per-Lambda schedule
#
# Each cleanup Lambda is on its own cron so blast radius is contained: a
# bug in the EBS cleanup doesn't delay the snapshot run, etc.
###############################################################################

resource "aws_cloudwatch_event_rule" "schedule" {
  for_each = local.enabled_types

  name                = "${var.name_prefix}-idle-${each.key}"
  description         = "Schedule for idle-${each.key} cleanup Lambda."
  schedule_expression = each.value.cron
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "target" {
  for_each = local.enabled_types

  rule      = aws_cloudwatch_event_rule.schedule[each.key].name
  target_id = each.key
  arn       = aws_lambda_function.this[each.key].arn
}

resource "aws_lambda_permission" "events" {
  for_each = local.enabled_types

  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[each.key].arn
}
