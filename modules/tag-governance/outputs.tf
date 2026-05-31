###############################################################################
# Outputs
###############################################################################

output "config_rule_names" {
  description = "Names of the AWS Config rules checking for required tags."
  value       = [for r in aws_config_config_rule.required_tags : r.name]
}

output "config_bucket" {
  description = "S3 bucket holding AWS Config delivery history (null if recorder disabled)."
  value       = var.enable_config_recorder ? aws_s3_bucket.config[0].id : null
}

output "tag_drift_event_rule_name" {
  description = "Name of the EventBridge rule that catches allocation-tag mutations (null if disabled)."
  value       = var.enable_tag_drift_detection && length(var.tag_drift_watched_keys) > 0 ? aws_cloudwatch_event_rule.tag_drift[0].name : null
}

output "allocation_resource_group_arns" {
  description = "Map of allocation-group name → ARN. Use in the AWS Console's Resource Groups view."
  value       = { for k, v in aws_resourcegroups_group.allocation : k => v.arn }
}

output "untagged_cost_lambda_arn" {
  description = "ARN of the untagged-cost report Lambda (null if not deployed)."
  value       = local.deploy_untagged_report ? aws_lambda_function.untagged_cost[0].arn : null
}

output "untagged_cost_dlq_arn" {
  description = "ARN of the untagged-cost report Lambda DLQ (null if not deployed)."
  value       = local.deploy_untagged_report ? aws_sqs_queue.untagged_cost_dlq[0].arn : null
}

output "metric_namespace" {
  description = "CloudWatch namespace under which tag-governance KPIs are published."
  value       = local.metric_namespace
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix under which tag-governance KPIs are mirrored."
  value       = local.ssm_prefix
}

output "mandatory_tag_keys" {
  description = "Resolved mandatory tag keys (from taxonomy if provided, else from required_tags)."
  value       = local.mandatory_tag_keys
}
