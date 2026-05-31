###############################################################################
# Outputs
###############################################################################

output "bucket_name" {
  description = "Cost-data S3 bucket name (CUR + FOCUS land here)."
  value       = aws_s3_bucket.cost_data.id
}

output "bucket_arn" {
  description = "Cost-data S3 bucket ARN."
  value       = aws_s3_bucket.cost_data.arn
}

output "cur2_export_arn" {
  description = "ARN of the CUR 2.0 BCM Data Export."
  value       = aws_bcmdataexports_export.cur2.arn
}

output "focus_export_arn" {
  description = "ARN of the FOCUS 1.0 BCM Data Export (null if disabled)."
  value       = var.enable_focus_export ? aws_bcmdataexports_export.focus[0].arn : null
}

output "athena_workgroup_name" {
  description = "Athena workgroup name (null if disabled)."
  value       = var.enable_athena_workgroup ? aws_athena_workgroup.finops[0].name : null
}

output "athena_database_name" {
  description = "Glue catalog database name (null if disabled)."
  value       = var.enable_athena_workgroup ? aws_glue_catalog_database.cur[0].name : null
}

output "cur2_table_name" {
  description = "Glue table name the crawler creates for CUR 2.0 (<namespace>_<env>_<stack>_data). Used by downstream Athena queries. Available only after the crawler's first successful run (~24-48h after first apply)."
  value       = var.enable_athena_workgroup ? local.cur2_table_name : null
}

output "cur_crawler_name" {
  description = "Glue crawler name (null if Athena workgroup disabled)."
  value       = var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : null
}

output "cross_account_reader_role_arns" {
  description = "Map of cross-account-reader logical name → IAM role ARN. Feed these into your 3rd-party FinOps tool's account-onboarding wizard."
  value       = { for k, r in aws_iam_role.cross_account_reader : k => r.arn }
}

output "named_query_ids" {
  description = "Map of named-query friendly name → Athena named-query ID. Visible in the Athena console under 'Saved queries'."
  value       = { for k, q in aws_athena_named_query.library : k => q.id }
}

output "health_check_lambda_arn" {
  description = "ARN of the daily health-check Lambda (null if disabled)."
  value       = var.enable_health_check ? aws_lambda_function.health_check[0].arn : null
}

output "health_check_dlq_arn" {
  description = "DLQ ARN for the health-check Lambda."
  value       = var.enable_health_check ? aws_sqs_queue.health_check_dlq[0].arn : null
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the cost-data-exports pipeline."
  value       = var.enable_health_check ? aws_cloudwatch_dashboard.cost_data[0].dashboard_name : null
}

output "metric_namespace" {
  description = "CloudWatch namespace under which health-check metrics are emitted."
  value       = local.metric_namespace
}
