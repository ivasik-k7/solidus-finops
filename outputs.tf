###############################################################################
# FinOps framework — root outputs
#
# Surface useful identifiers so other workspaces / observability tools can
# consume them via Terraform remote state, SSM, or external dashboards.
#
# Naming convention: every output is prefixed by the submodule that owns it,
# matching the variable convention. The exception is the top-level summary
# outputs (enabled_modules, framework_status) which describe the whole stack.
#
# Order matches variables.tf for grep-friendliness.
###############################################################################

###############################################################################
# Stack summary — what's deployed, where to find it
###############################################################################

output "name_prefix" {
  description = "Resource name prefix used by every module (<namespace>-<environment>-<stack>)."
  value       = local.name_prefix
}

output "enabled_modules" {
  description = "Map of module slug -> enabled flag. Useful for downstream tooling that needs to know which modules to expect outputs from."
  value = {
    alerting           = true
    cost_data_exports  = var.cost_data_exports_enabled
    tag_governance     = var.tag_governance_enabled
    budgets            = length(var.budgets_items) > 0
    idle_cleanup       = var.idle_cleanup_enabled
    instance_scheduler = var.instance_scheduler_enabled
    finops_metrics     = var.finops_metrics_enabled && var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled
  }
}

output "framework_status" {
  description = "Single-glance status of the framework — what's on, where the dashboards live, and the IDs you'll usually want."
  value = {
    name_prefix       = local.name_prefix
    primary_region    = var.aws_primary_region
    secondary_regions = var.aws_secondary_regions
    effective_regions = local.effective_regions
    kms_key_arn       = local.kms_key_arn
    events_topic_arn  = local.events_topic_arn
    dashboards = {
      cost_data_exports  = var.cost_data_exports_enabled ? module.cost_data_exports[0].dashboard_name : null
      budgets            = length(var.budgets_items) > 0 ? module.budgets[0].dashboard_name : null
      idle_cleanup       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].dashboard_name : null
      instance_scheduler = var.instance_scheduler_enabled ? module.instance_scheduler[0].dashboard_name : null
    }
  }
}

output "effective_regions" {
  description = "Resolved scan-reach: [aws_primary_region] + aws_secondary_regions. The default value used by any per-module *_scan_regions that's left empty."
  value       = local.effective_regions
}

###############################################################################
# Shared primitives — KMS + events bus
###############################################################################

output "kms_key_arn" {
  description = "KMS key ARN used for FinOps data encryption."
  value       = local.kms_key_arn
}

output "events_topic_arn" {
  description = "SNS topic ARN for FinOps events (alerts, reports, governance). Subscribe additional listeners here."
  value       = local.events_topic_arn
}

###############################################################################
# Alerting
###############################################################################

output "alerting_dispatcher_lambda_arn" {
  description = "Multi-channel dispatcher Lambda ARN (null if no dispatch channels configured)."
  value       = module.alerting.dispatcher_lambda_arn
}

output "alerting_events_table_name" {
  description = "DynamoDB table holding alerting AUDIT + DEDUP rows."
  value       = module.alerting.events_table_name
}

output "alerting_channel_secret_arns" {
  description = "Map of channel-key → Secrets Manager ARN (only for channels created via inline webhook/key)."
  value       = module.alerting.channel_secret_arns
}

output "alerting_webhook_secret_arns" {
  description = "ARNs of Secrets Manager secrets holding chat webhook URLs (null for any unconfigured channel)."
  value = {
    slack = module.alerting.slack_webhook_secret_arn
    teams = module.alerting.teams_webhook_secret_arn
  }
}

###############################################################################
# Cost data exports
###############################################################################

output "cost_data_exports_bucket_name" {
  description = "S3 bucket holding CUR and FOCUS exports."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].bucket_name : null
}

output "cost_data_exports_bucket_arn" {
  description = "S3 bucket ARN holding CUR and FOCUS exports."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].bucket_arn : null
}

output "cost_data_exports_cur2_export_arn" {
  description = "ARN of the CUR 2.0 BCM Data Export."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].cur2_export_arn : null
}

output "cost_data_exports_focus_export_arn" {
  description = "ARN of the FOCUS 1.0 BCM Data Export (null if disabled)."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].focus_export_arn : null
}

output "cost_data_exports_cur2_table_name" {
  description = "Glue table name discovered by the CUR 2.0 crawler. Null until first crawler run (~24-48h after first apply)."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].cur2_table_name : null
}

output "cost_data_exports_crawler_name" {
  description = "Glue crawler name that discovers the CUR 2.0 table."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].cur_crawler_name : null
}

output "cost_data_exports_cross_account_reader_role_arns" {
  description = "Map of cross-account reader (e.g. cloudability) → IAM role ARN. Feed into the 3rd-party tool's account onboarding."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].cross_account_reader_role_arns : {}
}

output "cost_data_exports_named_query_ids" {
  description = "Map of pre-built Athena named-query name → ID. Visible in Athena console > Saved queries."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].named_query_ids : {}
}

output "cost_data_exports_dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the cost-data-exports pipeline."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].dashboard_name : null
}

output "cost_data_exports_metric_namespace" {
  description = "CloudWatch namespace under which cost-data-exports health-check metrics are published."
  value       = var.cost_data_exports_enabled ? module.cost_data_exports[0].metric_namespace : null
}

output "cost_data_exports_athena_workgroup_name" {
  description = "Athena workgroup for querying CUR data."
  value       = var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled ? module.cost_data_exports[0].athena_workgroup_name : null
}

output "cost_data_exports_athena_database_name" {
  description = "Glue/Athena database holding the CUR table."
  value       = var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled ? module.cost_data_exports[0].athena_database_name : null
}

###############################################################################
# Tag governance
###############################################################################

output "tag_governance_config_rule_names" {
  description = "Names of the AWS Config rules checking for required tags."
  value       = var.tag_governance_enabled ? module.tag_governance[0].config_rule_names : []
}

output "tag_governance_drift_event_rule_name" {
  description = "EventBridge rule name capturing allocation-tag mutations (null if disabled)."
  value       = var.tag_governance_enabled ? module.tag_governance[0].tag_drift_event_rule_name : null
}

output "tag_governance_allocation_resource_group_arns" {
  description = "Map of allocation resource-group name → ARN."
  value       = var.tag_governance_enabled ? module.tag_governance[0].allocation_resource_group_arns : {}
}

output "tag_governance_metric_namespace" {
  description = "CloudWatch namespace under which tag-governance KPIs (coverage %, untagged-cost, health score) are published."
  value       = var.tag_governance_enabled ? module.tag_governance[0].metric_namespace : null
}

output "tag_governance_ssm_prefix" {
  description = "SSM Parameter Store path prefix for tag-governance KPI mirrors."
  value       = var.tag_governance_enabled ? module.tag_governance[0].ssm_prefix : null
}

output "tag_governance_mandatory_tag_keys" {
  description = "Resolved mandatory tag keys (taxonomy if provided, else tag_governance_required_tags)."
  value       = var.tag_governance_enabled ? module.tag_governance[0].mandatory_tag_keys : []
}

###############################################################################
# Budgets
###############################################################################

output "budgets_ids" {
  description = "Map of budget key -> Budgets resource ID."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].budget_ids : {}
}

output "budgets_names" {
  description = "Map of budget key -> budget name."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].budget_names : {}
}

output "budgets_action_ids" {
  description = "Map of `<budget>-action-<idx>` → AWS Budget Action ID."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].budget_action_ids : {}
}

output "budgets_state_table_name" {
  description = "DynamoDB state + trend + audit-log table for budget performance tracking (null if disabled)."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].state_table_name : null
}

output "budgets_metric_namespace" {
  description = "CloudWatch namespace for budget KPIs (VariancePct, BurnRateDaysToBreach, BudgetAdherenceScore, ...)."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].metric_namespace : null
}

output "budgets_ssm_prefix" {
  description = "SSM Parameter Store prefix for aggregate budget KPI mirrors."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].ssm_prefix : null
}

output "budgets_dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the budgets module."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].dashboard_name : null
}

output "budgets_actions_role_arn" {
  description = "Execution role ARN used by AWS Budget Actions (null if no actions configured)."
  value       = length(var.budgets_items) > 0 ? module.budgets[0].budget_actions_role_arn : null
}

###############################################################################
# Idle resource cleanup
###############################################################################

output "idle_cleanup_lambda_arns" {
  description = "ARNs of the idle-resource-cleanup Lambdas, keyed by resource type (ebs / eip / snapshot / nat / eni / lb)."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].lambda_arns : {}
}

output "idle_cleanup_enabled_types" {
  description = "Resource types currently being scanned by the idle-resource-cleanup module."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].enabled_resource_types : []
}

output "idle_cleanup_metric_namespace" {
  description = "CloudWatch namespace under which idle-resource KPIs (MonthlyWasteUsd, FoundCount, ActionsTakenCount, RunSavingsUsd) are published."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].metric_namespace : null
}

output "idle_cleanup_findings_table_name" {
  description = "DynamoDB table holding per-resource STATE rows + append-only ACTION audit log."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].findings_table_name : null
}

output "idle_cleanup_dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the idle-resource-cleanup module."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].dashboard_name : null
}

output "idle_cleanup_scan_regions" {
  description = "Regions the idle-resource-cleanup Lambdas iterate over."
  value       = var.idle_cleanup_enabled ? module.idle_resource_cleanup[0].scan_regions : []
}

###############################################################################
# Instance scheduler
###############################################################################

output "instance_scheduler_lambda_arn" {
  description = "ARN of the instance scheduler Lambda."
  value       = var.instance_scheduler_enabled ? module.instance_scheduler[0].lambda_arn : null
}

output "instance_scheduler_discovery_lambda_arn" {
  description = "ARN of the weekly auto-discovery Lambda (null if disabled)."
  value       = var.instance_scheduler_enabled ? module.instance_scheduler[0].discovery_lambda_arn : null
}

output "instance_scheduler_state_table_name" {
  description = "DynamoDB table holding scheduler STATE + ACTION rows."
  value       = var.instance_scheduler_enabled ? module.instance_scheduler[0].state_table_name : null
}

output "instance_scheduler_dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the scheduler."
  value       = var.instance_scheduler_enabled ? module.instance_scheduler[0].dashboard_name : null
}

output "instance_scheduler_metric_namespace" {
  description = "CloudWatch namespace for scheduler metrics (FinOps/InstanceScheduler)."
  value       = var.instance_scheduler_enabled ? module.instance_scheduler[0].metric_namespace : null
}

###############################################################################
# FinOps metrics
###############################################################################

output "finops_metrics_namespace" {
  description = "CloudWatch namespace under which FinOps KPIs are published."
  value       = (var.finops_metrics_enabled && var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled) ? module.finops_metrics[0].metric_namespace : null
}

output "finops_metrics_ssm_prefix" {
  description = "SSM Parameter Store path prefix under which FinOps KPIs are mirrored."
  value       = (var.finops_metrics_enabled && var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled) ? module.finops_metrics[0].ssm_prefix : null
}

output "finops_metrics_named_query_ids" {
  description = "Athena named-query IDs registered by the finops-metrics module."
  value       = (var.finops_metrics_enabled && var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled) ? module.finops_metrics[0].named_query_ids : {}
}

###############################################################################
# Cross-module ops glue — aggregate DLQ index
###############################################################################

output "lambda_dlq_arns" {
  description = "ARNs of every Lambda dead-letter queue, keyed by Lambda identity. Subscribe a monitoring tool here to catch unprocessed events."
  value = merge(
    module.alerting.chat_notifier_dlq_arn == null ? {} : { chat_notifier = module.alerting.chat_notifier_dlq_arn },
    var.idle_cleanup_enabled ? { for k, v in module.idle_resource_cleanup[0].dlq_arns : "idle_${k}" => v } : {},
    var.instance_scheduler_enabled ? { instance_scheduler = module.instance_scheduler[0].dlq_arn } : {},
    var.instance_scheduler_enabled ? (
      module.instance_scheduler[0].discovery_dlq_arn == null ? {} : { instance_scheduler_discovery = module.instance_scheduler[0].discovery_dlq_arn }
    ) : {},
    (var.finops_metrics_enabled && var.cost_data_exports_enabled && var.cost_data_exports_athena_enabled) ? { finops_metrics = module.finops_metrics[0].dlq_arn } : {},
    var.tag_governance_enabled ? (
      module.tag_governance[0].untagged_cost_dlq_arn == null ? {} : { tag_governance_untagged_cost = module.tag_governance[0].untagged_cost_dlq_arn }
    ) : {},
    (length(var.budgets_items) > 0 && var.budgets_performance_tracking_enabled) ? { budget_performance = module.budgets[0].performance_dlq_arn } : {},
    (var.cost_data_exports_enabled && var.cost_data_exports_health_check_enabled) ? { cost_data_health = module.cost_data_exports[0].health_check_dlq_arn } : {},
  )
}
