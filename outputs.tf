###############################################################################
# Root outputs
#
# Surface useful identifiers so other workspaces / observability tools can
# consume them via Terraform remote state, SSM Parameter Store, etc.
###############################################################################

output "kms_key_arn" {
  description = "KMS key ARN used for FinOps data encryption."
  value       = local.kms_key_arn
}

output "events_topic_arn" {
  description = "SNS topic ARN for FinOps events (alerts, reports, governance). Subscribe additional listeners here."
  value       = local.events_topic_arn
}

output "cost_data_bucket_name" {
  description = "S3 bucket holding CUR and FOCUS exports."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].bucket_name : null
}

output "cost_data_bucket_arn" {
  description = "S3 bucket ARN holding CUR and FOCUS exports."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].bucket_arn : null
}

output "cur2_export_arn" {
  description = "ARN of the CUR 2.0 BCM Data Export."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].cur2_export_arn : null
}

output "focus_export_arn" {
  description = "ARN of the FOCUS 1.0 BCM Data Export (null if disabled)."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].focus_export_arn : null
}

output "cur2_table_name" {
  description = "Glue table name discovered by the CUR 2.0 crawler. Null until first crawler run (~24-48h after first apply)."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].cur2_table_name : null
}

output "cur_crawler_name" {
  description = "Glue crawler name that discovers the CUR 2.0 table."
  value       = var.enable_cost_data_exports ? module.cost_data_exports[0].cur_crawler_name : null
}

output "athena_workgroup_name" {
  description = "Athena workgroup for querying CUR data."
  value       = var.enable_cost_data_exports && var.enable_athena_workgroup ? module.cost_data_exports[0].athena_workgroup_name : null
}

output "athena_database_name" {
  description = "Glue/Athena database holding the CUR table."
  value       = var.enable_cost_data_exports && var.enable_athena_workgroup ? module.cost_data_exports[0].athena_database_name : null
}

output "anomaly_monitor_arns" {
  description = "Cost Anomaly Detection monitor ARNs."
  value       = var.enable_anomaly_detection ? module.anomaly_detection[0].monitor_arns : []
}

output "cost_category_arns" {
  description = "Cost Category ARNs for use in Cost Explorer and CUR joins."
  value       = length(var.cost_categories) > 0 ? module.cost_categories[0].category_arns : {}
}

output "budget_ids" {
  description = "Map of budget key -> Budgets resource ID."
  value       = length(var.budgets) > 0 ? module.budgets[0].budget_ids : {}
}

output "budget_names" {
  description = "Map of budget key -> budget name."
  value       = length(var.budgets) > 0 ? module.budgets[0].budget_names : {}
}

output "tag_compliance_config_rule_names" {
  description = "Names of the AWS Config rules checking for required tags."
  value       = module.tag_governance.config_rule_names
}

output "tag_drift_event_rule_name" {
  description = "EventBridge rule name capturing allocation-tag mutations (null if disabled)."
  value       = module.tag_governance.tag_drift_event_rule_name
}

output "allocation_resource_group_arns" {
  description = "Map of allocation resource-group name → ARN."
  value       = module.tag_governance.allocation_resource_group_arns
}

output "tag_governance_metric_namespace" {
  description = "CloudWatch namespace under which tag-governance KPIs (coverage %, untagged-cost, health score) are published."
  value       = module.tag_governance.metric_namespace
}

output "tag_governance_ssm_prefix" {
  description = "SSM Parameter Store path prefix for tag-governance KPI mirrors."
  value       = module.tag_governance.ssm_prefix
}

output "mandatory_tag_keys" {
  description = "Resolved mandatory tag keys (taxonomy if provided, else required_tags)."
  value       = module.tag_governance.mandatory_tag_keys
}

output "idle_cleanup_lambda_arns" {
  description = "ARNs of the idle-resource-cleanup Lambdas, keyed by resource type (ebs / eip / snapshot / nat / eni / lb)."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].lambda_arns : {}
}

output "idle_cleanup_enabled_types" {
  description = "Resource types currently being scanned by the idle-resource-cleanup module."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].enabled_resource_types : []
}

output "idle_cleanup_metric_namespace" {
  description = "CloudWatch namespace under which idle-resource KPIs (MonthlyWasteUsd, FoundCount, ActionsTakenCount, RunSavingsUsd) are published."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].metric_namespace : null
}

output "idle_cleanup_findings_table_name" {
  description = "DynamoDB table holding per-resource STATE rows + append-only ACTION audit log."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].findings_table_name : null
}

output "idle_cleanup_dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the idle-resource-cleanup module."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].dashboard_name : null
}

output "idle_cleanup_scan_regions" {
  description = "Regions the idle-resource-cleanup Lambdas iterate over."
  value       = var.enable_idle_cleanup ? module.idle_resource_cleanup[0].scan_regions : []
}

output "instance_scheduler_lambda_arn" {
  description = "ARN of the instance scheduler Lambda."
  value       = var.enable_instance_scheduler ? module.instance_scheduler[0].lambda_arn : null
}

output "savings_coverage_reporter_lambda_arn" {
  description = "ARN of the savings coverage reporter Lambda."
  value       = var.enable_savings_coverage_reporter ? module.savings_coverage_reporter[0].lambda_arn : null
}

output "webhook_secret_arns" {
  description = "ARNs of Secrets Manager secrets holding chat webhook URLs (null for any unconfigured channel)."
  value = {
    slack = module.alerting.slack_webhook_secret_arn
    teams = module.alerting.teams_webhook_secret_arn
  }
}

output "lambda_dlq_arns" {
  description = "ARNs of every Lambda dead-letter queue, keyed by Lambda identity. Subscribe a monitoring tool here to catch unprocessed events."
  value = merge(
    module.alerting.chat_notifier_dlq_arn == null ? {} : { chat_notifier = module.alerting.chat_notifier_dlq_arn },
    var.enable_idle_cleanup ? { for k, v in module.idle_resource_cleanup[0].dlq_arns : "idle_${k}" => v } : {},
    var.enable_instance_scheduler ? { instance_scheduler = module.instance_scheduler[0].dlq_arn } : {},
    var.enable_savings_coverage_reporter ? { savings_coverage_reporter = module.savings_coverage_reporter[0].dlq_arn } : {},
    (var.enable_finops_metrics && var.enable_cost_data_exports && var.enable_athena_workgroup) ? { finops_metrics = module.finops_metrics[0].dlq_arn } : {},
    module.tag_governance.untagged_cost_dlq_arn == null ? {} : { tag_governance_untagged_cost = module.tag_governance.untagged_cost_dlq_arn },
  )
}

output "finops_metrics_namespace" {
  description = "CloudWatch namespace under which FinOps KPIs are published."
  value       = (var.enable_finops_metrics && var.enable_cost_data_exports && var.enable_athena_workgroup) ? module.finops_metrics[0].metric_namespace : null
}

output "finops_metrics_ssm_prefix" {
  description = "SSM Parameter Store path prefix under which FinOps KPIs are mirrored."
  value       = (var.enable_finops_metrics && var.enable_cost_data_exports && var.enable_athena_workgroup) ? module.finops_metrics[0].ssm_prefix : null
}

output "finops_metrics_named_query_ids" {
  description = "Athena named-query IDs registered by the finops-metrics module."
  value       = (var.enable_finops_metrics && var.enable_cost_data_exports && var.enable_athena_workgroup) ? module.finops_metrics[0].named_query_ids : {}
}
