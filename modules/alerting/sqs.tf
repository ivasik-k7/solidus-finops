###############################################################################
# SQS — dispatcher DLQ
#
# Created only when at least one dispatch channel is configured. Default 14d
# retention + SSE-SQS encryption (no CMK; queue holds opaque event payloads
# already in the SNS topic, which IS CMK-encrypted).
###############################################################################

resource "aws_sqs_queue" "dispatcher_dlq" {
  count = local.any_dispatch_channels ? 1 : 0

  name                      = "${var.name_prefix}-dispatcher-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}
