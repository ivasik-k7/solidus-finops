###############################################################################
# SQS dead-letter queues — one per Lambda
#
# SSE-SQS managed encryption (not CMK) — keeps the Lambda's KMS policy simple.
# DLQ messages aren't long-term audit data; that lives in the DDB ACTION rows.
###############################################################################

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.name_prefix}-scheduler-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}

resource "aws_sqs_queue" "discovery_dlq" {
  count = var.enable_discovery ? 1 : 0

  name                      = "${var.name_prefix}-scheduler-discovery-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}
