###############################################################################
# Outputs — the standalone contract
###############################################################################

output "lambda_arn" {
  description = "Scheduler Lambda ARN."
  value       = aws_lambda_function.scheduler.arn
}

output "lambda_function_name" {
  description = "Scheduler Lambda function name."
  value       = aws_lambda_function.scheduler.function_name
}

output "dlq_arn" {
  description = "Scheduler DLQ ARN — wire your observability stack here."
  value       = aws_sqs_queue.scheduler_dlq.arn
}

output "discovery_lambda_arn" {
  description = "Auto-discovery Lambda ARN (null if disabled)."
  value       = var.enable_discovery ? aws_lambda_function.discovery[0].arn : null
}

output "discovery_dlq_arn" {
  description = "Auto-discovery DLQ ARN (null if disabled)."
  value       = var.enable_discovery ? aws_sqs_queue.discovery_dlq[0].arn : null
}

output "state_table_name" {
  description = "DynamoDB table holding scheduler STATE + ACTION rows. Query this for per-resource history."
  value       = aws_dynamodb_table.state.name
}

output "state_table_arn" {
  description = "DynamoDB state table ARN."
  value       = aws_dynamodb_table.state.arn
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.scheduler.dashboard_name
}

output "dashboard_url" {
  description = "Click-through URL for the CloudWatch dashboard."
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.scheduler.dashboard_name}"
}

output "metric_namespace" {
  description = "CloudWatch namespace under which scheduler metrics are published (FinOps/InstanceScheduler)."
  value       = local.metric_namespace
}

output "scan_regions" {
  description = "Effective list of regions the scheduler iterates (resolved from var.scan_regions or the home region)."
  value       = local.effective_regions
}

output "schedules_configured" {
  description = "Number of named schedules supplied to the module. Useful for external alerting — if this drops to 0 the scheduler is effectively a no-op."
  value       = local.schedules_count
}

output "tag_keys" {
  description = "Tag keys this module reads on resources. Document these for application teams."
  value = {
    opt_in         = var.opt_in_tag_key
    exception      = var.exception_tag_key
    override_until = var.override_until_tag_key
  }
}
