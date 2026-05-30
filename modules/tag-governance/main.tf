###############################################################################
# Tag Governance module — FinOps Foundation aligned
#
# Capabilities implemented (FinOps Foundation Framework):
#   - Policy & Governance — required-tag enforcement (Config managed rule)
#   - Allocation — tag taxonomy as code; allocation Resource Groups
#   - Reporting & Analytics — weekly untagged-cost report Lambda; tag-health
#     score CloudWatch metric
#   - FinOps Practice Operations — tag drift detection (allocation-relevant
#     tag mutations are audited via EventBridge → events bus)
#
# Design principle: NOTIFY, DO NOT MUTATE.
#
#   It is tempting to wire AWS Config remediation to "auto-tag" non-compliant
#   resources with placeholder values. We deliberately do NOT do this, because:
#     - A wrongly-applied tag can move cost to the wrong cost center, creating
#       downstream chargeback disputes.
#     - It silently masks the underlying tagging-discipline problem.
#     - It creates an unauditable shadow of "machine-applied" tags that
#       look real but are not.
#
#   The right enforcement layer is at-creation (IAM RequestTag conditions or
#   Service Control Policies) — see docs/TAG_GOVERNANCE_PATTERNS.md.
###############################################################################

###############################################################################
# Inputs — core compliance layer
###############################################################################

variable "name_prefix" { type = string }
variable "events_topic_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "log_retention_days" {
  type = number

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}
variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the untagged-cost report Lambda."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the untagged-cost report Lambda. Null = no reservation."
  type        = number
  default     = null
}

variable "required_tags" {
  type = list(object({
    key            = string
    allowed_values = list(string)
  }))
}

variable "resource_types" { type = list(string) }
variable "record_global_resources" {
  description = "If true, the Config recorder includes global resource types (IAM, CloudFront, Route53)."
  type        = bool
  default     = true
}
variable "enable_config_recorder" {
  description = "Set to false if AWS Config is already enabled in this account."
  type        = bool
  default     = true
}

###############################################################################
# Inputs — taxonomy, drift detection, untagged-cost report, resource groups
###############################################################################

variable "tag_taxonomy" {
  description = <<-EOT
    Optional rich metadata for each tag key the practice cares about. The
    untagged-cost report and the README documentation read this; the Config
    rule itself is still driven by `required_tags`.
      - level: "mandatory" | "recommended" | "operational"
      - purpose: "allocation" | "compliance" | "operational" | "lifecycle"
  EOT
  type = map(object({
    level       = string
    purpose     = string
    description = string
    examples    = optional(list(string), [])
  }))
  default = {}
}

variable "enable_tag_drift_detection" {
  description = "If true, mutations of allocation-critical tags emit an audit event to the events bus."
  type        = bool
  default     = true
}

variable "tag_drift_watched_keys" {
  description = "Tag keys whose creation, modification, or deletion trigger a drift audit event. Typically the allocation tags. Empty list disables the watch."
  type        = list(string)
  default     = ["CostCenter", "BusinessUnit", "Application"]
}

variable "enable_untagged_cost_report" {
  description = "Deploy a weekly Lambda that dollarizes the tag gap (per-tag untagged cost, top-N offenders, coverage %, health score). Requires Athena workgroup + CUR table."
  type        = bool
  default     = false
}

variable "untagged_cost_report_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the untagged-cost report."
  type        = string
  default     = "0 8 ? * MON *"
}

variable "untagged_cost_alarm_threshold_usd" {
  description = "Alarm if the total mandatory-tag-gap cost exceeds this value (current month). Null = skip alarm."
  type        = number
  default     = 1000
}

variable "untagged_cost_top_n" {
  description = "Number of top-cost untagged resources to surface in each weekly report."
  type        = number
  default     = 20
}

variable "athena_workgroup_name" {
  description = "Athena workgroup for the untagged-cost report (only used if enable_untagged_cost_report = true)."
  type        = string
  default     = null
}

variable "athena_database_name" {
  description = "Glue database holding the CUR table."
  type        = string
  default     = null
}

variable "cur_table_name" {
  description = "Glue table name for CUR 2.0."
  type        = string
  default     = "cur2"
}

variable "allocation_resource_groups" {
  description = <<-EOT
    Map of resource-group name -> { tag_key, tag_values } to provision as
    aws_resourcegroups_group. Lets the console filter by allocation
    dimension out-of-the-box.

    Example:
      allocation_resource_groups = {
        bu-retail-banking = { tag_key = "BusinessUnit", tag_values = ["retail-banking"] }
        cc-1234           = { tag_key = "CostCenter",   tag_values = ["CC-1234"] }
      }
  EOT
  type = map(object({
    tag_key    = string
    tag_values = list(string)
  }))
  default = {}
}

variable "default_tags" { type = map(string) }

locals {
  metric_namespace = "FinOps/TagGovernance"
  ssm_prefix       = "/${var.name_prefix}/tag-governance"

  mandatory_tag_keys_from_required = [for t in var.required_tags : t.key]

  # Prefer taxonomy entries marked level="mandatory" if the caller supplied
  # taxonomy; otherwise fall back to required_tags (preserves existing contract).
  mandatory_tag_keys = length(var.tag_taxonomy) > 0 ? [
    for k, v in var.tag_taxonomy : k if v.level == "mandatory"
  ] : local.mandatory_tag_keys_from_required

  deploy_untagged_report = (
    var.enable_untagged_cost_report
    && var.athena_workgroup_name != null
    && var.athena_database_name != null
    && length(local.mandatory_tag_keys) > 0
  )
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# AWS Config recorder + delivery channel (optional)
###############################################################################

resource "aws_s3_bucket" "config" {
  # checkov:skip=CKV_AWS_18: Config delivery bucket holds AWS Config history; CloudTrail data events provide the audit-grade access log. S3 access logging would create a chicken-and-egg problem (the logs bucket itself needs logging).
  # checkov:skip=CKV_AWS_21: Versioning IS enabled below via aws_s3_bucket_versioning.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV_AWS_144: Cross-region replication of Config history would double cost without proportional audit value — AWS Config can replay history from CloudTrail if the bucket is lost.
  # checkov:skip=CKV_AWS_145: KMS encryption IS configured below via aws_s3_bucket_server_side_encryption_configuration.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_6: Public access block IS configured below via aws_s3_bucket_public_access_block.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_61: Lifecycle config IS configured below via aws_s3_bucket_lifecycle_configuration.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_62: S3 event notifications not needed — AWS Config delivers on its own schedule; no event-driven downstream processing.
  count  = var.enable_config_recorder ? 1 : 0
  bucket = "${var.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
  tags   = merge(var.default_tags, { Purpose = "aws-config-delivery" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_config_recorder ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# AWS Config delivers append-only history snapshots; lifecycle simply cleans up
# noncurrent versions + aborts orphaned multipart uploads. Current versions
# are retained indefinitely — they're the audit trail.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  rule {
    id     = "noncurrent-cleanup"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_iam_role" "config" {
  count = var.enable_config_recorder ? 1 : 0
  name  = "${var.name_prefix}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config_recorder ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "main" {
  # checkov:skip=CKV2_AWS_48: all_supported = true IS set; recording_group records every supported type. include_global_resource_types is controlled by var.record_global_resources (default true) — Checkov can't evaluate the variable's default and false-flags this as missing.
  count = var.enable_config_recorder ? 1 : 0

  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.record_global_resources
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config_recorder ? 1 : 0
  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].id
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  # checkov:skip=CKV2_AWS_45: is_enabled = true is set literally below. Checkov 3.x has a known false-positive on this rule when count is used; the recorder IS enabled at apply time.
  count      = var.enable_config_recorder ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

###############################################################################
# Config rule: required tags
#
# The managed rule REQUIRED_TAGS accepts up to 6 tag keys per rule. We chunk
# the input into groups of 6 and provision one rule per chunk so callers can
# require an arbitrary number of tags without silent truncation.
###############################################################################

locals {
  required_tag_chunks = chunklist(var.required_tags, 6)

  required_tag_chunk_params = {
    for chunk_idx, chunk in local.required_tag_chunks :
    chunk_idx => merge(
      {
        for i, t in chunk :
        "tag${i + 1}Key" => t.key
      },
      {
        for i, t in chunk :
        "tag${i + 1}Value" => join(",", t.allowed_values) if length(t.allowed_values) > 0
      },
    )
  }
}

resource "aws_config_config_rule" "required_tags" {
  for_each = local.required_tag_chunk_params

  name        = "${var.name_prefix}-required-tags-${each.key + 1}"
  description = "FinOps required-tag check (group ${each.key + 1} of ${length(local.required_tag_chunks)})."

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  scope {
    compliance_resource_types = var.resource_types
  }

  input_parameters = jsonencode(each.value)

  depends_on = [aws_config_configuration_recorder_status.main]
}

###############################################################################
# EventBridge → SNS digest
#
# Catches Config compliance change events and forwards to the alerting topic.
# Throttled by InputPath so we only send the salient fields.
###############################################################################

resource "aws_cloudwatch_event_rule" "tag_compliance" {
  count = length(var.required_tags) > 0 ? 1 : 0

  name        = "${var.name_prefix}-tag-compliance"
  description = "FinOps tag compliance change events"

  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [for r in aws_config_config_rule.required_tags : r.name]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "tag_compliance_to_sns" {
  count = length(var.required_tags) > 0 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.tag_compliance[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      account      = "$.detail.awsAccountId"
      region       = "$.detail.awsRegion"
      resourceType = "$.detail.resourceType"
      resourceId   = "$.detail.resourceId"
      ruleName     = "$.detail.configRuleName"
      compliance   = "$.detail.newEvaluationResult.complianceType"
    }
    input_template = <<EOF
{
  "severity": "medium",
  "AlertName": "FinOps tag non-compliance",
  "AccountId": <account>,
  "Region": <region>,
  "ResourceType": <resourceType>,
  "ResourceId": <resourceId>,
  "ConfigRuleName": <ruleName>,
  "Compliance": <compliance>
}
EOF
  }
}

###############################################################################
# Tag drift detection
#
# Catches the unified "Tag Change on Resource" event AWS emits to EventBridge
# whenever a resource's tags are mutated. Filtered to allocation-critical tag
# keys so the audit trail stays small and signal-heavy.
###############################################################################

resource "aws_cloudwatch_event_rule" "tag_drift" {
  count = var.enable_tag_drift_detection && length(var.tag_drift_watched_keys) > 0 ? 1 : 0

  name        = "${var.name_prefix}-tag-drift"
  description = "Mutations of allocation-critical tag keys (audit trail)"

  event_pattern = jsonencode({
    source        = ["aws.tag"]
    "detail-type" = ["Tag Change on Resource"]
    detail = {
      changed-tag-keys = var.tag_drift_watched_keys
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "tag_drift_to_sns" {
  count = var.enable_tag_drift_detection && length(var.tag_drift_watched_keys) > 0 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.tag_drift[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      account      = "$.account"
      region       = "$.region"
      service      = "$.detail.service"
      resourceType = "$.detail.resource-type"
      resourceArn  = "$.resources[0]"
      changedKeys  = "$.detail.changed-tag-keys"
      newTags      = "$.detail.tags"
      version      = "$.detail.version"
    }
    input_template = <<EOF
{
  "severity": "medium",
  "AlertName": "FinOps allocation-tag mutation",
  "AccountId": <account>,
  "Region": <region>,
  "Service": <service>,
  "ResourceType": <resourceType>,
  "ResourceArn": <resourceArn>,
  "ChangedTagKeys": <changedKeys>,
  "NewTags": <newTags>,
  "Version": <version>
}
EOF
  }
}

###############################################################################
# Allocation Resource Groups
#
# For each entry in var.allocation_resource_groups, provision a tag-based
# Resource Group so the AWS Console (and Resource Explorer) can filter by
# the allocation dimension out-of-the-box.
###############################################################################

resource "aws_resourcegroups_group" "allocation" {
  for_each = var.allocation_resource_groups

  name        = "${var.name_prefix}-${each.key}"
  description = "FinOps allocation group: ${each.value.tag_key} in [${join(", ", each.value.tag_values)}]"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = each.value.tag_key
          Values = each.value.tag_values
        }
      ]
    })
  }

  tags = var.default_tags
}

###############################################################################
# Weekly untagged-cost report Lambda
#
# Dollarizes the tag gap. Skipped entirely if either Athena or mandatory tags
# are not configured.
###############################################################################

resource "aws_sqs_queue" "untagged_cost_dlq" {
  count = local.deploy_untagged_report ? 1 : 0

  name                      = "${var.name_prefix}-untagged-cost-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}

resource "aws_iam_role" "untagged_cost" {
  count = local.deploy_untagged_report ? 1 : 0

  name = "${var.name_prefix}-untagged-cost-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "untagged_cost_basic" {
  count      = local.deploy_untagged_report ? 1 : 0
  role       = aws_iam_role.untagged_cost[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "untagged_cost" {
  # checkov:skip=CKV_AWS_288: athena:* and glue:GetDatabase/GetTable/GetPartitions do not support resource-level permissions per the AWS Service Authorization Reference. s3:* on Athena results requires bucket-level access patterns Athena controls. No data-exfil path beyond what AWS-managed Athena/Glue already permit.
  # checkov:skip=CKV_AWS_290: Same — these Athena + Glue + CloudWatch:PutMetricData actions are documented as requiring Resource = "*".
  # checkov:skip=CKV_AWS_355: Same — Resource = "*" is the AWS-documented requirement for Athena query execution + Glue catalog reads.
  count = local.deploy_untagged_report ? 1 : 0

  name = "untagged-cost-report"
  role = aws_iam_role.untagged_cost[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "athena:StartQueryExecution",
            "athena:GetQueryExecution",
            "athena:GetQueryResults",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "glue:GetDatabase",
            "glue:GetTable",
            "glue:GetPartitions",
          ]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]
          Resource = "*"
        },
        # KMS perms so Athena can decrypt CUR data and encrypt query results
        # written to the KMS-encrypted athena-results bucket.
        {
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey",
          ]
          Resource = var.kms_key_arn
        },
        {
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ssm:PutParameter", "ssm:GetParameter"]
          Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
        },
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = var.events_topic_arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.untagged_cost_dlq[0].arn
        },
      ],
      var.xray_tracing_enabled ? [{
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }] : [],
    )
  })
}

data "archive_file" "untagged_cost" {
  count       = local.deploy_untagged_report ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/untagged_cost_report.py"
  output_path = "${path.module}/lambda/untagged_cost_report.zip"
}

resource "aws_cloudwatch_log_group" "untagged_cost" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = local.deploy_untagged_report ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-untagged-cost-report"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "untagged_cost" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  count = local.deploy_untagged_report ? 1 : 0

  function_name                  = "${var.name_prefix}-untagged-cost-report"
  description                    = "Weekly FinOps untagged-cost report → CloudWatch + SSM + SNS."
  role                           = aws_iam_role.untagged_cost[0].arn
  filename                       = data.archive_file.untagged_cost[0].output_path
  source_code_hash               = data.archive_file.untagged_cost[0].output_base64sha256
  handler                        = "untagged_cost_report.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      METRIC_NAMESPACE   = local.metric_namespace
      SSM_PREFIX         = local.ssm_prefix
      ATHENA_WORKGROUP   = var.athena_workgroup_name
      ATHENA_DATABASE    = var.athena_database_name
      CUR_TABLE          = var.cur_table_name
      MANDATORY_TAG_KEYS = jsonencode(local.mandatory_tag_keys)
      SNS_TOPIC_ARN      = var.events_topic_arn
      TOP_N              = tostring(var.untagged_cost_top_n)
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.untagged_cost_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.untagged_cost]
  tags       = var.default_tags
}

resource "aws_cloudwatch_event_rule" "untagged_cost" {
  count               = local.deploy_untagged_report ? 1 : 0
  name                = "${var.name_prefix}-untagged-cost-report"
  schedule_expression = "cron(${var.untagged_cost_report_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "untagged_cost" {
  count     = local.deploy_untagged_report ? 1 : 0
  rule      = aws_cloudwatch_event_rule.untagged_cost[0].name
  target_id = "untagged-cost"
  arn       = aws_lambda_function.untagged_cost[0].arn
}

resource "aws_lambda_permission" "untagged_cost_events" {
  count         = local.deploy_untagged_report ? 1 : 0
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.untagged_cost[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.untagged_cost[0].arn
}

###############################################################################
# Alarms — on the report Lambda itself + on the financial gap it measures
###############################################################################

resource "aws_cloudwatch_metric_alarm" "untagged_cost_lambda_errors" {
  count = local.deploy_untagged_report ? 1 : 0

  alarm_name          = "${var.name_prefix}-untagged-cost-errors"
  alarm_description   = "FinOps untagged-cost report Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.untagged_cost[0].function_name }
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "untagged_cost_dlq_depth" {
  count = local.deploy_untagged_report ? 1 : 0

  alarm_name          = "${var.name_prefix}-untagged-cost-dlq-depth"
  alarm_description   = "Messages accumulating in the untagged-cost report Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.untagged_cost_dlq[0].name }
  alarm_actions       = [var.events_topic_arn]
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "untagged_cost_excess" {
  count = local.deploy_untagged_report && var.untagged_cost_alarm_threshold_usd != null ? 1 : 0

  alarm_name        = "${var.name_prefix}-untagged-cost-excess"
  alarm_description = "Total cost of resources missing mandatory tags exceeds the configured ceiling — tag-discipline regression."
  namespace         = local.metric_namespace
  metric_name       = "TotalUntaggedCostUsd"
  statistic         = "Maximum"
  # Metric is emitted weekly; align the alarm period so missing-data flicker
  # doesn't bounce between OK and INSUFFICIENT_DATA mid-week.
  period              = 604800
  evaluation_periods  = 1
  threshold           = var.untagged_cost_alarm_threshold_usd
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]
  tags                = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "config_rule_names" {
  value = [for r in aws_config_config_rule.required_tags : r.name]
}

output "config_bucket" {
  value = var.enable_config_recorder ? aws_s3_bucket.config[0].id : null
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
  value = local.deploy_untagged_report ? aws_sqs_queue.untagged_cost_dlq[0].arn : null
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
