###############################################################################
# Outputs
###############################################################################

output "lambda_arns" {
  description = "Map of resource-type → Lambda ARN."
  value       = { for k, fn in aws_lambda_function.this : k => fn.arn }
}

output "dlq_arns" {
  description = "Map of resource-type → SQS DLQ ARN."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.arn }
}

output "schedule_rule_names" {
  description = "Map of resource-type → EventBridge schedule rule name."
  value       = { for k, r in aws_cloudwatch_event_rule.schedule : k => r.name }
}

output "metric_namespace" {
  description = "CloudWatch namespace under which idle-resource KPIs are published."
  value       = local.metric_namespace
}

output "enabled_resource_types" {
  description = "Resource types actively scanned (post enable-flag resolution)."
  value       = keys(local.enabled_types)
}

output "findings_table_name" {
  description = "DynamoDB table holding per-resource STATE + ACTION audit rows."
  value       = aws_dynamodb_table.findings.name
}

output "findings_table_arn" {
  description = "ARN of the findings DynamoDB table — wire into downstream analytics."
  value       = aws_dynamodb_table.findings.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard auto-provisioned for the FinOps lead's single pane of glass."
  value       = aws_cloudwatch_dashboard.idle_cleanup.dashboard_name
}

output "scan_regions" {
  description = "Regions each Lambda scans (defaults to home region if unset at the root)."
  value       = length(var.scan_regions) > 0 ? var.scan_regions : [data.aws_region.current.region]
}
