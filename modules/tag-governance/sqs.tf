###############################################################################
# SQS — DLQ for the untagged-cost report Lambda
###############################################################################

resource "aws_sqs_queue" "untagged_cost_dlq" {
  count = local.deploy_untagged_report ? 1 : 0

  name                      = "${var.name_prefix}-untagged-cost-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}
