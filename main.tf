###############################################################################
# Root module composition
#
# The root module wires the framework together. Each sub-module is independently
# usable, but the root composition is the typical entry point.
###############################################################################

###############################################################################
# KMS key for FinOps data encryption
#
# Used to encrypt:
#   - The CUR/FOCUS S3 bucket
#   - The events SNS topic
#   - All Lambda environment variables and CloudWatch log groups
#
# Key policy follows least-privilege: account root admin, plus specific service
# principals that need to read/write encrypted data.
###############################################################################

resource "aws_kms_key" "finops" {
  count = var.create_kms_key ? 1 : 0

  description             = "FinOps framework data encryption key"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBillingReportsService"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid    = "AllowBCMDataExportsService"
        Effect = "Allow"
        Principal = {
          Service = "bcm-data-exports.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid    = "AllowSNSService"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${local.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:*"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${local.name_prefix}-data-key"
  }

  # Guardrail: prevent accidental destroy of the key that decrypts years of
  # audit data. To intentionally destroy, remove this block first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "finops" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${local.name_prefix}-data"
  target_key_id = aws_kms_key.finops[0].key_id
}

###############################################################################
# Module: alerting (the events bus)
#
# Deployed FIRST because everything else publishes to it.
###############################################################################

module "alerting" {
  source = "./modules/alerting"

  name_prefix         = local.name_prefix
  kms_key_arn         = local.kms_key_arn
  notification_emails = var.notification_emails
  slack_webhook_url   = var.slack_webhook_url
  teams_webhook_url   = var.teams_webhook_url
  log_retention_days  = var.log_retention_days
  lambda_runtime      = var.lambda_runtime
  default_tags        = local.default_tags
}

###############################################################################
# Module: cost-data-exports
###############################################################################

module "cost_data_exports" {
  source = "./modules/cost-data-exports"
  count  = var.enable_cost_data_exports ? 1 : 0

  name_prefix               = local.name_prefix
  bucket_name               = local.cost_data_bucket_name
  kms_key_arn               = local.kms_key_arn
  enable_focus_export       = var.enable_focus_export
  enable_athena_workgroup   = var.enable_athena_workgroup
  cost_data_retention_days  = var.cost_data_retention_days
  cost_data_expiration_days = var.cost_data_expiration_days
  account_id                = local.account_id
  default_tags              = local.default_tags
}

###############################################################################
# Module: budgets
###############################################################################

module "budgets" {
  source = "./modules/budgets"
  count  = length(var.budgets) > 0 ? 1 : 0

  name_prefix      = local.name_prefix
  events_topic_arn = local.events_topic_arn
  currency         = var.budget_currency
  budgets          = var.budgets
  default_tags     = local.default_tags

  # Budgets with scope = "cost_category" reference a category by name+value;
  # the category must exist when the budget is created. Force the order.
  depends_on = [module.cost_categories]
}

###############################################################################
# Module: anomaly-detection
###############################################################################

module "anomaly_detection" {
  source = "./modules/anomaly-detection"
  count  = var.enable_anomaly_detection ? 1 : 0

  name_prefix       = local.name_prefix
  events_topic_arn  = local.events_topic_arn
  min_impact_amount = var.anomaly_min_impact_amount
  min_impact_pct    = var.anomaly_min_impact_pct
  default_tags      = local.default_tags
}

###############################################################################
# Module: cost-categories
###############################################################################

module "cost_categories" {
  source = "./modules/cost-categories"
  count  = length(var.cost_categories) > 0 ? 1 : 0

  cost_categories = var.cost_categories
  default_tags    = local.default_tags
}

###############################################################################
# Module: tag-governance
###############################################################################

module "tag_governance" {
  source = "./modules/tag-governance"

  name_prefix              = local.name_prefix
  required_tags            = var.required_tags
  resource_types           = var.tag_compliance_resource_types
  record_global_resources  = var.tag_governance_record_global_resources
  events_topic_arn         = local.events_topic_arn
  kms_key_arn              = local.kms_key_arn
  log_retention_days       = var.log_retention_days
  lambda_runtime           = var.lambda_runtime

  # Enriched FinOps capabilities
  tag_taxonomy                       = var.tag_taxonomy
  enable_tag_drift_detection         = var.enable_tag_drift_detection
  tag_drift_watched_keys             = var.tag_drift_watched_keys
  enable_untagged_cost_report        = var.enable_untagged_cost_report && var.enable_cost_data_exports && var.enable_athena_workgroup
  untagged_cost_report_cron          = var.untagged_cost_report_cron
  untagged_cost_alarm_threshold_usd  = var.untagged_cost_alarm_threshold_usd
  athena_workgroup_name              = var.enable_cost_data_exports && var.enable_athena_workgroup ? module.cost_data_exports[0].athena_workgroup_name : null
  athena_database_name               = var.enable_cost_data_exports && var.enable_athena_workgroup ? module.cost_data_exports[0].athena_database_name : null
  cur_table_name                     = var.enable_cost_data_exports && var.enable_athena_workgroup ? module.cost_data_exports[0].cur2_table_name : "unset"
  allocation_resource_groups         = var.allocation_resource_groups

  default_tags = local.default_tags
}

###############################################################################
# Module: optimization-services
###############################################################################

module "optimization_services" {
  source = "./modules/optimization-services"

  enable_compute_optimizer     = var.enable_compute_optimizer
  enable_cost_optimization_hub = var.enable_cost_optimization_hub
}

###############################################################################
# Module: idle-resource-cleanup
###############################################################################

module "idle_resource_cleanup" {
  source = "./modules/idle-resource-cleanup"
  count  = var.enable_idle_cleanup ? 1 : 0

  name_prefix                = local.name_prefix
  events_topic_arn           = local.events_topic_arn
  kms_key_arn                = local.kms_key_arn
  log_retention_days         = var.log_retention_days
  lambda_runtime             = var.lambda_runtime
  dry_run                    = var.idle_cleanup_dry_run
  exception_tag_key          = var.idle_cleanup_exception_tag_key
  ebs_min_age_days           = var.idle_cleanup_ebs_min_age_days
  snapshot_min_age_days      = var.idle_cleanup_snapshot_min_age_days
  scan_regions               = var.idle_cleanup_scan_regions
  aging_seen_count_threshold = var.idle_cleanup_aging_seen_count_threshold
  default_tags               = local.default_tags
}

###############################################################################
# Module: instance-scheduler
###############################################################################

module "instance_scheduler" {
  source = "./modules/instance-scheduler"
  count  = var.enable_instance_scheduler ? 1 : 0

  name_prefix        = local.name_prefix
  events_topic_arn   = local.events_topic_arn
  kms_key_arn        = local.kms_key_arn
  log_retention_days = var.log_retention_days
  lambda_runtime     = var.lambda_runtime
  opt_in_tag_key     = var.instance_scheduler_opt_in_tag_key
  schedules          = var.instance_scheduler_schedules
  default_tags       = local.default_tags
}

###############################################################################
# Module: savings-coverage-reporter
###############################################################################

###############################################################################
# Module: finops-metrics
#
# Requires cost-data-exports + Athena workgroup. Emits KPIs to CloudWatch + SSM
# and registers Athena named queries against the framework's workgroup.
###############################################################################

module "finops_metrics" {
  source = "./modules/finops-metrics"
  count  = var.enable_finops_metrics && var.enable_cost_data_exports && var.enable_athena_workgroup ? 1 : 0

  name_prefix            = local.name_prefix
  events_topic_arn       = local.events_topic_arn
  kms_key_arn            = local.kms_key_arn
  log_retention_days     = var.log_retention_days
  lambda_runtime         = var.lambda_runtime
  athena_workgroup_name  = module.cost_data_exports[0].athena_workgroup_name
  athena_database_name   = module.cost_data_exports[0].athena_database_name
  cur_table_name         = module.cost_data_exports[0].cur2_table_name
  allocation_tag_keys    = var.finops_metrics_allocation_tag_keys
  aggregator_cron        = var.finops_metrics_aggregator_cron
  alarm_thresholds       = var.finops_metrics_alarm_thresholds
  default_tags           = local.default_tags
}

module "savings_coverage_reporter" {
  source = "./modules/savings-coverage-reporter"
  count  = var.enable_savings_coverage_reporter ? 1 : 0

  name_prefix         = local.name_prefix
  events_topic_arn    = local.events_topic_arn
  kms_key_arn         = local.kms_key_arn
  log_retention_days  = var.log_retention_days
  lambda_runtime      = var.lambda_runtime
  report_cron         = var.savings_coverage_report_cron
  target_coverage_pct = var.savings_coverage_target_pct
  default_tags        = local.default_tags
}
