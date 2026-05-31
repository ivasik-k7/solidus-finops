###############################################################################
# SQS — per-Lambda DLQs
#
# One DLQ per enabled resource type. SSE-SQS managed encryption (no CMK —
# queues hold transient invocation context, the DDB findings table is the
# durable audit trail and IS CMK-encrypted).
###############################################################################

resource "aws_sqs_queue" "dlq" {
  for_each = local.enabled_types

  name                      = "${var.name_prefix}-idle-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}
