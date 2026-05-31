###############################################################################
# SQS — health-check Lambda DLQ
###############################################################################

resource "aws_sqs_queue" "health_check_dlq" {
  count = var.enable_health_check ? 1 : 0

  name                      = "${var.name_prefix}-cost-data-health-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}
