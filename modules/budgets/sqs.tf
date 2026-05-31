###############################################################################
# SQS — performance Lambda DLQ
###############################################################################

resource "aws_sqs_queue" "perf_dlq" {
  count = var.enable_performance_tracking ? 1 : 0

  name                      = "${var.name_prefix}-budget-perf-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}
