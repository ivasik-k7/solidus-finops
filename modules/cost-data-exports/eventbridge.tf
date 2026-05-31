###############################################################################
# EventBridge — health-check schedule + Glue crawler state forwarder
#
#   1. health_check rule          daily trigger for the health-check Lambda
#   2. crawler_state rule         forwards Glue crawler Succeeded/Failed
#                                 events to the events SNS topic (only if
#                                 var.events_topic_arn is set AND Athena is on)
###############################################################################

# ---------------------------------------------------------------------------
# Health-check schedule
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "health_check" {
  count               = var.enable_health_check ? 1 : 0
  name                = "${var.name_prefix}-cost-data-health"
  schedule_expression = "cron(${var.health_check_schedule_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "health_check" {
  count     = var.enable_health_check ? 1 : 0
  rule      = aws_cloudwatch_event_rule.health_check[0].name
  target_id = "health-check"
  arn       = aws_lambda_function.health_check[0].arn
}

resource "aws_lambda_permission" "health_check_events" {
  count         = var.enable_health_check ? 1 : 0
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_check[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check[0].arn
}

# ---------------------------------------------------------------------------
# Glue crawler state forwarder
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "crawler_state" {
  count = var.events_topic_arn != null && var.enable_athena_workgroup ? 1 : 0

  name        = "${var.name_prefix}-crawler-state"
  description = "Forward Glue crawler state changes to the events bus"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Crawler State Change"]
    detail = {
      crawlerName = [aws_glue_crawler.cur[0].name]
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "crawler_state_to_sns" {
  count = var.events_topic_arn != null && var.enable_athena_workgroup ? 1 : 0

  rule      = aws_cloudwatch_event_rule.crawler_state[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      crawler = "$.detail.crawlerName"
      state   = "$.detail.state"
      message = "$.detail.message"
      ts      = "$.time"
    }
    input_template = <<EOF
{
  "AlertName": "FinOps CUR crawler state change",
  "severity": "info",
  "Crawler": <crawler>,
  "State": <state>,
  "Message": <message>,
  "Timestamp": <ts>
}
EOF
  }
}
