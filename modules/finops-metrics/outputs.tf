###############################################################################
# Outputs — the standalone contract
###############################################################################

output "aggregator_lambda_arn" {
  description = "Aggregator Lambda ARN."
  value       = aws_lambda_function.aggregator.arn
}

output "aggregator_lambda_function_name" {
  description = "Aggregator Lambda function name."
  value       = aws_lambda_function.aggregator.function_name
}

output "dlq_arn" {
  description = "Aggregator DLQ ARN. Wire your monitoring tool here."
  value       = aws_sqs_queue.dlq.arn
}

output "metric_namespace" {
  description = "CloudWatch namespace under which KPIs are published (FinOps/KPIs)."
  value       = local.metric_namespace
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix under which scalar KPIs are mirrored (/<name_prefix>/kpis)."
  value       = local.ssm_prefix
}

output "snapshot_table_name" {
  description = "DynamoDB table holding daily KPI snapshots. Query directly for custom trend analysis."
  value       = aws_dynamodb_table.snapshots.name
}

output "snapshot_table_arn" {
  description = "ARN of the KPI snapshot table."
  value       = aws_dynamodb_table.snapshots.arn
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard. Lambda re-PUTs this on every run with trend + per-tag-value widgets."
  value       = aws_cloudwatch_dashboard.kpis.dashboard_name
}

output "dashboard_url" {
  description = "Click-through URL to the dashboard."
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.kpis.dashboard_name}"
}

output "named_query_ids" {
  description = "Map of built-in + custom Athena named-query name → ID. Visible in Athena console > Saved queries."
  value = merge(
    var.builtin_kpis_enabled.allocation_coverage ? { allocation_coverage = aws_athena_named_query.allocation_coverage[0].id } : {},
    var.builtin_kpis_enabled.spend_by_service ? { spend_by_service = aws_athena_named_query.spend_by_service[0].id } : {},
    var.builtin_kpis_enabled.allocation_coverage ? { unit_cost_by_business_unit = aws_athena_named_query.unit_cost_by_business_unit[0].id } : {},
    { month_over_month_growth = aws_athena_named_query.month_over_month_growth.id },
    { for k, q in aws_athena_named_query.custom : "custom_${k}" => q.id },
  )
}

output "enabled_kpis" {
  description = "Map of KPI slug -> enabled flag. Useful for downstream tooling that wants to know which metric names to expect."
  value = {
    allocation_coverage    = var.builtin_kpis_enabled.allocation_coverage
    commitment_coverage    = var.builtin_kpis_enabled.commitment_coverage
    commitment_utilization = var.builtin_kpis_enabled.commitment_utilization
    anomaly_impact         = var.builtin_kpis_enabled.anomaly_impact
    forecast_drift         = var.builtin_kpis_enabled.forecast_drift
    spend_by_service       = var.builtin_kpis_enabled.spend_by_service
    trend_metrics          = var.trend_metrics_enabled
    tag_value_dashboard    = var.tag_value_dashboard_tag != null
    custom_count           = length(var.custom_kpis)
  }
}

output "custom_kpi_metric_names" {
  description = "Metric names emitted for user-defined custom KPIs. Pattern: Custom_<key>."
  value       = [for k in keys(var.custom_kpis) : "Custom_${k}"]
}
