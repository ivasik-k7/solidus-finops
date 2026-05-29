###############################################################################
# SQS — aggregator DLQ
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-kpi-aggregator-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}
