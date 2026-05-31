###############################################################################
# SNS — the events bus
#
# Every framework module publishes here. Policy allows the account owner +
# AWS service principals (budgets, costalerts, events, cloudwatch) with a
# SourceAccount condition.
###############################################################################

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = var.default_tags
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# ---------------------------------------------------------------------------
# Email subscriptions — one per address, native SNS (no Lambda hop).
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "email" {
  for_each = { for s in local.email_subscriptions : s.address => s }

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value.address
}

# ---------------------------------------------------------------------------
# Dispatcher subscription — Lambda fan-out.
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "dispatcher" {
  count     = local.any_dispatch_channels ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.dispatcher[0].arn
}
