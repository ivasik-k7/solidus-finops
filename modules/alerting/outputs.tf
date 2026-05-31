###############################################################################
# Outputs — the standalone-friendly contract.
#
# Pre-v0.2 outputs (chat_notifier_*, slack_webhook_secret_arn, etc.) are
# preserved as compatibility aliases so callers don't break across the
# rename to "dispatcher".
###############################################################################

output "events_topic_arn" {
  description = "ARN of the SNS topic publishers should write to."
  value       = aws_sns_topic.alerts.arn
}

output "events_topic_name" {
  description = "Name of the SNS topic."
  value       = aws_sns_topic.alerts.name
}

output "dispatcher_lambda_arn" {
  description = "Dispatcher Lambda ARN (null if no dispatch channels configured)."
  value       = local.any_dispatch_channels ? aws_lambda_function.dispatcher[0].arn : null
}

output "dispatcher_dlq_arn" {
  description = "Dispatcher DLQ ARN."
  value       = local.any_dispatch_channels ? aws_sqs_queue.dispatcher_dlq[0].arn : null
}

output "events_table_name" {
  description = "DynamoDB table for audit log + dedup cache."
  value       = length(aws_dynamodb_table.events) > 0 ? aws_dynamodb_table.events[0].name : null
}

output "channel_secret_arns" {
  description = "Map of channel-key → Secrets Manager ARN (for channels where the inline URL/key was provided)."
  value = merge(
    { for k, s in aws_secretsmanager_secret.slack : k => s.arn },
    { for k, s in aws_secretsmanager_secret.teams : k => s.arn },
    { for k, s in aws_secretsmanager_secret.pagerduty : k => s.arn },
    { for k, s in aws_secretsmanager_secret.opsgenie : k => s.arn },
    { for k, s in aws_secretsmanager_secret.webhook : k => s.arn },
  )
}

# ---------------------------------------------------------------------------
# Backward-compatibility aliases (so root composition doesn't break).
# ---------------------------------------------------------------------------

output "chat_notifier_lambda_arn" {
  description = "Backward-compat alias of dispatcher_lambda_arn."
  value       = local.any_dispatch_channels ? aws_lambda_function.dispatcher[0].arn : null
}

output "chat_notifier_dlq_arn" {
  description = "Backward-compat alias of dispatcher_dlq_arn."
  value       = local.any_dispatch_channels ? aws_sqs_queue.dispatcher_dlq[0].arn : null
}

output "slack_webhook_secret_arn" {
  description = "Backward-compat: first Slack channel's secret ARN (null if none)."
  value       = length(aws_secretsmanager_secret.slack) > 0 ? values(aws_secretsmanager_secret.slack)[0].arn : null
}

output "teams_webhook_secret_arn" {
  description = "Backward-compat: first Teams channel's secret ARN (null if none)."
  value       = length(aws_secretsmanager_secret.teams) > 0 ? values(aws_secretsmanager_secret.teams)[0].arn : null
}
