###############################################################################
# Outputs
###############################################################################

output "budget_ids" {
  description = "Map of budget key → Budgets resource ID."
  value       = { for k, v in aws_budgets_budget.this : k => v.id }
}

output "budget_names" {
  description = "Map of budget key → budget name."
  value       = { for k, v in aws_budgets_budget.this : k => v.name }
}

output "budget_action_ids" {
  description = "Map of budget action key → Budgets Action ID."
  value       = { for k, v in aws_budgets_budget_action.this : k => v.id }
}

output "state_table_name" {
  description = "DynamoDB table holding STATE / SNAPSHOT / ACTION rows for budget performance tracking (null if disabled)."
  value       = var.enable_performance_tracking ? aws_dynamodb_table.state[0].name : null
}

output "state_table_arn" {
  description = "DynamoDB state table ARN."
  value       = var.enable_performance_tracking ? aws_dynamodb_table.state[0].arn : null
}

output "performance_lambda_arn" {
  description = "Budget performance Lambda ARN (null if disabled)."
  value       = var.enable_performance_tracking ? aws_lambda_function.performance[0].arn : null
}

output "performance_dlq_arn" {
  description = "Budget performance Lambda DLQ ARN."
  value       = var.enable_performance_tracking ? aws_sqs_queue.perf_dlq[0].arn : null
}

output "metric_namespace" {
  description = "CloudWatch namespace under which budget KPIs are published."
  value       = local.metric_namespace
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix for budget KPI mirrors."
  value       = local.ssm_prefix
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard name."
  value       = var.enable_performance_tracking ? aws_cloudwatch_dashboard.budgets[0].dashboard_name : null
}

output "budget_actions_role_arn" {
  description = "Execution role ARN used by AWS Budget Actions (null if no actions configured)."
  value       = length(local.actions_map) > 0 ? aws_iam_role.budget_actions[0].arn : null
}
