###############################################################################
# Idle Resource Cleanup module — FinOps Foundation aligned
#
# Detects (and optionally cleans) idle resources across multiple AWS services.
# Every resource type:
#   - Has its own Lambda + IAM role + DLQ + Errors alarm + DLQ-depth alarm
#   - Honors `var.dry_run` (default true) and the exception tag
#   - Emits CloudWatch metrics under namespace FinOps/IdleResources, dimension
#     ResourceType=<type>:  MonthlyWasteUsd, FoundCount, ActionsTakenCount
#   - Publishes a structured digest to the events SNS topic
#   - Respects a per-Lambda cost ceiling (USD/run) to bound blast radius
#
# Resource coverage (each individually toggleable):
#   - EBS volumes — unattached, with TWO-PHASE snapshot-then-delete: phase 1
#     snapshots + tags the volume; phase 2 (next run) finalizes only when the
#     snapshot has completed and a grace period has elapsed. No race.
#   - Elastic IPs — unassociated
#   - EBS snapshots — orphaned (not AMI-backed)
#   - NAT Gateways — idle by both age and CloudWatch BytesOutToDestination
#   - ENIs — leaked/unattached
#   - Load Balancers — ALB/NLB with no healthy targets + low request count
###############################################################################

###############################################################################
# Inputs
###############################################################################

variable "name_prefix" { type = string }
variable "events_topic_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "log_retention_days" { type = number }
variable "lambda_runtime" { type = string }
variable "default_tags" { type = map(string) }

variable "dry_run" {
  description = "When true (default), every cleanup Lambda only reports. When false, mutation-capable scans actually delete (still bounded by cost ceiling + exception tags)."
  type        = bool
  default     = true
}

variable "exception_tag_key" {
  description = "Tag key that excludes a resource from cleanup. Default 'FinOpsException'."
  type        = string
  default     = "FinOpsException"
}

variable "cost_ceiling_usd" {
  description = "Maximum monthly USD value of resources any single Lambda will act on per invocation. Caps blast radius if detection misfires. Per-resource overrides via cost_ceiling_<type>_usd if needed (not currently exposed)."
  type        = number
  default     = 10000
}

# Per-resource-type toggles ----------------------------------------------------

variable "enable_ebs_cleanup" {
  type    = bool
  default = true
}
variable "enable_eip_cleanup" {
  type    = bool
  default = true
}
variable "enable_snapshot_cleanup" {
  type    = bool
  default = true
}
variable "enable_nat_cleanup" {
  type    = bool
  default = true
}
variable "enable_eni_cleanup" {
  type    = bool
  default = true
}
variable "enable_lb_cleanup" {
  type    = bool
  default = true
}

# Per-resource-type age / threshold ------------------------------------------

variable "ebs_min_age_days" { type = number }
variable "snapshot_min_age_days" { type = number }

variable "nat_min_age_days" {
  type    = number
  default = 14
}
variable "nat_idle_lookback_days" {
  type    = number
  default = 7
}
variable "nat_idle_bytes_threshold" {
  type    = number
  default = 1048576 # 1 MiB / day
}
variable "eni_min_age_days" {
  type    = number
  default = 7
}
variable "lb_min_age_days" {
  type    = number
  default = 14
}
variable "lb_idle_lookback_days" {
  type    = number
  default = 7
}
variable "lb_idle_request_threshold" {
  type    = number
  default = 100
}

# EBS phase-2 grace -----------------------------------------------------------

variable "ebs_pending_grace_hours" {
  description = "Hours a volume must stay in 'FinOpsPendingDeletion=<snap>' state before phase-2 deletion finalizes."
  type        = number
  default     = 24
}

variable "ebs_pending_grace_max_hours" {
  description = "Hours after which a pending-deletion volume rolls back (tags cleared, error surfaced)."
  type        = number
  default     = 168 # 7 days
}

# Per-resource schedules ------------------------------------------------------

variable "ebs_schedule" {
  type    = string
  default = "cron(0 9 ? * MON *)"
}
variable "snapshot_schedule" {
  type    = string
  default = "cron(0 10 ? * MON *)"
}
variable "nat_schedule" {
  type    = string
  default = "cron(0 11 ? * MON *)"
}
variable "lb_schedule" {
  type    = string
  default = "cron(0 12 ? * MON *)"
}
variable "eip_schedule" {
  type    = string
  default = "cron(0 13 ? * MON *)"
}
variable "eni_schedule" {
  type    = string
  default = "cron(0 14 ? * MON *)"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Multi-region + state-tracking inputs
###############################################################################

variable "scan_regions" {
  description = "Regions to scan for idle resources. Each Lambda iterates these in turn and uses regional boto3 clients. Empty list = the Lambda's home region only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.scan_regions : can(regex("^[a-z]{2}-[a-z]+-\\d$", r))])
    error_message = "Every scan_regions entry must be a valid AWS region code (e.g. eu-central-1)."
  }
}

variable "aging_seen_count_threshold" {
  description = "Number of consecutive scans the same resource must appear in before its severity is bumped to high — signals an ignored finding."
  type        = number
  default     = 10
}

variable "findings_ttl_days" {
  description = "Days a STATE row is retained in DynamoDB after it stops appearing in scans. Action-log rows use a longer retention via the audit table."
  type        = number
  default     = 90
}

variable "actions_ttl_days" {
  description = "Days an ACTION row (deletion / release / snapshot) is retained. Default 7 years for audit-grade trail."
  type        = number
  default     = 2557
}

###############################################################################
# DynamoDB — findings state + action audit log
#
# Single-table design:
#   PK = "<ResourceType>#<ResourceId>"   (e.g. "EBS#vol-0abc1234")
#   SK = "STATE" | "ACTION#<iso-ts>"
#
# STATE rows carry the current lifecycle state (new / aging / snoozed /
# excepted / approved / deleted) with TTL so stale findings auto-expire.
#
# ACTION rows are append-only and form the audit trail — every mutation
# (snapshot, delete, release) lands here with the estimated $ saved and
# the actor identifier.
###############################################################################

resource "aws_dynamodb_table" "findings" {
  name         = "${var.name_prefix}-idle-findings"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "Status"
    type = "S"
  }

  # GSI on Status — supports "show me everything snoozed / excepted / approved".
  global_secondary_index {
    name            = "ByStatus"
    hash_key        = "Status"
    range_key       = "PK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ExpireAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = var.default_tags

  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# Locals — resource-type catalog
###############################################################################

locals {
  metric_namespace = "FinOps/IdleResources"

  # Single source of truth for the resource types this module manages.
  # `enabled` gates everything (Lambda, IAM, DLQ, alarms, schedule).
  catalog = {
    ebs = {
      enabled = var.enable_ebs_cleanup
      handler = "ebs_cleanup.handler"
      source  = "ebs_cleanup.py"
      timeout = 900
      memory  = 512
      cron    = var.ebs_schedule
      env = {
        MIN_AGE_DAYS            = tostring(var.ebs_min_age_days)
        PENDING_GRACE_HOURS     = tostring(var.ebs_pending_grace_hours)
        PENDING_GRACE_MAX_HOURS = tostring(var.ebs_pending_grace_max_hours)
      }
    }
    eip = {
      enabled = var.enable_eip_cleanup
      handler = "eip_cleanup.handler"
      source  = "eip_cleanup.py"
      timeout = 300
      memory  = 256
      cron    = var.eip_schedule
      env     = {}
    }
    snapshot = {
      enabled = var.enable_snapshot_cleanup
      handler = "snapshot_cleanup.handler"
      source  = "snapshot_cleanup.py"
      timeout = 900
      memory  = 512
      cron    = var.snapshot_schedule
      env     = { MIN_AGE_DAYS = tostring(var.snapshot_min_age_days) }
    }
    nat = {
      enabled = var.enable_nat_cleanup
      handler = "nat_cleanup.handler"
      source  = "nat_cleanup.py"
      timeout = 600
      memory  = 256
      cron    = var.nat_schedule
      env = {
        MIN_AGE_DAYS         = tostring(var.nat_min_age_days)
        IDLE_LOOKBACK_DAYS   = tostring(var.nat_idle_lookback_days)
        IDLE_BYTES_THRESHOLD = tostring(var.nat_idle_bytes_threshold)
      }
    }
    eni = {
      enabled = var.enable_eni_cleanup
      handler = "eni_cleanup.handler"
      source  = "eni_cleanup.py"
      timeout = 300
      memory  = 256
      cron    = var.eni_schedule
      env     = { MIN_AGE_DAYS = tostring(var.eni_min_age_days) }
    }
    lb = {
      enabled = var.enable_lb_cleanup
      handler = "lb_cleanup.handler"
      source  = "lb_cleanup.py"
      timeout = 600
      memory  = 256
      cron    = var.lb_schedule
      env = {
        MIN_AGE_DAYS           = tostring(var.lb_min_age_days)
        IDLE_LOOKBACK_DAYS     = tostring(var.lb_idle_lookback_days)
        IDLE_REQUEST_THRESHOLD = tostring(var.lb_idle_request_threshold)
      }
    }
  }

  # IAM policy statements per resource type. Same key as catalog. Mutation
  # actions are granted regardless of dry_run — IAM has no dry-run mode, the
  # Lambda enforces it. Includes sqs:SendMessage on its own DLQ + sns:Publish
  # + cloudwatch:PutMetricData common to all.
  iam_statements = {
    ebs = [
      {
        Effect = "Allow",
        Action = [
          "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:DescribeTags",
          "ec2:CreateSnapshot", "ec2:DeleteVolume", "ec2:CreateTags",
          "ec2:DeleteTags",
        ],
        Resource = "*",
      },
    ]
    eip = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeAddresses", "ec2:ReleaseAddress"],
        Resource = "*",
      },
    ]
    snapshot = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeSnapshots", "ec2:DescribeImages", "ec2:DeleteSnapshot"],
        Resource = "*",
      },
    ]
    nat = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeNatGateways", "ec2:DeleteNatGateway"],
        Resource = "*",
      },
      {
        Effect   = "Allow",
        Action   = ["cloudwatch:GetMetricStatistics"],
        Resource = "*",
      },
    ]
    eni = [
      {
        Effect   = "Allow",
        Action   = ["ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"],
        Resource = "*",
      },
    ]
    lb = [
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DeleteLoadBalancer",
        ],
        Resource = "*",
      },
      {
        Effect   = "Allow",
        Action   = ["cloudwatch:GetMetricStatistics"],
        Resource = "*",
      },
    ]
  }

  enabled_types = { for k, v in local.catalog : k => v if v.enabled }

  common_env = {
    DRY_RUN                    = tostring(var.dry_run)
    EXCEPTION_TAG_KEY          = var.exception_tag_key
    SNS_TOPIC_ARN              = var.events_topic_arn
    METRIC_NAMESPACE           = local.metric_namespace
    COST_CEILING_USD           = tostring(var.cost_ceiling_usd)
    FINDINGS_TABLE_NAME        = aws_dynamodb_table.findings.name
    AGING_SEEN_COUNT_THRESHOLD = tostring(var.aging_seen_count_threshold)
    FINDINGS_TTL_DAYS          = tostring(var.findings_ttl_days)
    ACTIONS_TTL_DAYS           = tostring(var.actions_ttl_days)
    SCAN_REGIONS               = jsonencode(length(var.scan_regions) > 0 ? var.scan_regions : [data.aws_region.current.region])
  }
}

###############################################################################
# Per-Lambda DLQs (SSE-SQS, 14d retention)
###############################################################################

resource "aws_sqs_queue" "dlq" {
  for_each = local.enabled_types

  name                      = "${var.name_prefix}-idle-${each.key}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}

###############################################################################
# Per-Lambda IAM roles — least-privilege per resource type
###############################################################################

resource "aws_iam_role" "this" {
  for_each = local.enabled_types

  name = "${var.name_prefix}-idle-${each.key}-role"
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

resource "aws_iam_role_policy_attachment" "basic" {
  for_each   = local.enabled_types
  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "this" {
  for_each = local.enabled_types

  name = "${each.key}-cleanup"
  role = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.iam_statements[each.key],
      [
        { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*" },
        { Effect = "Allow", Action = ["sns:Publish"], Resource = var.events_topic_arn },
        { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq[each.key].arn },
        # DDB findings state + audit log access (scoped to the findings table
        # only, including its GSIs).
        {
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:BatchWriteItem",
          ]
          Resource = [
            aws_dynamodb_table.findings.arn,
            "${aws_dynamodb_table.findings.arn}/index/*",
          ]
        },
        # KMS perms so the Lambda can encrypt/decrypt DDB items.
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
      ],
    )
  })
}

###############################################################################
# Lambda packaging
#
# Each Lambda's zip bundles:
#   - the resource-type-specific entrypoint (e.g. ebs_cleanup.py)
#   - the shared idle_state.py helper (DDB state + audit log)
#
# Using multi-source archive_file rather than a Lambda Layer keeps the
# per-Lambda blast radius small (no shared layer to bump on every change).
###############################################################################

data "archive_file" "lambda" {
  for_each    = local.enabled_types
  type        = "zip"
  output_path = "${path.module}/lambda/${each.key}_cleanup.zip"

  source {
    content  = file("${path.module}/lambda/${each.key}/${each.value.source}")
    filename = each.value.source
  }

  source {
    content  = file("${path.module}/lambda/_shared/idle_state.py")
    filename = "idle_state.py"
  }
}

###############################################################################
# Per-Lambda CloudWatch log group (CMK-encrypted)
###############################################################################

resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.enabled_types
  name              = "/aws/lambda/${var.name_prefix}-idle-${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

###############################################################################
# Lambda functions
###############################################################################

resource "aws_lambda_function" "this" {
  for_each = local.enabled_types

  function_name    = "${var.name_prefix}-idle-${each.key}"
  description      = "Idle ${each.key} detector + (optional) cleanup. dry_run=${var.dry_run}."
  role             = aws_iam_role.this[each.key].arn
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  handler          = each.value.handler
  runtime          = var.lambda_runtime
  timeout          = each.value.timeout
  memory_size      = each.value.memory
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = merge(local.common_env, each.value.env)
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq[each.key].arn
  }

  depends_on = [aws_cloudwatch_log_group.this]
  tags       = var.default_tags
}

###############################################################################
# Per-Lambda EventBridge schedule
###############################################################################

resource "aws_cloudwatch_event_rule" "schedule" {
  for_each = local.enabled_types

  name                = "${var.name_prefix}-idle-${each.key}"
  description         = "Schedule for idle-${each.key} cleanup Lambda."
  schedule_expression = each.value.cron
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "target" {
  for_each = local.enabled_types

  rule      = aws_cloudwatch_event_rule.schedule[each.key].name
  target_id = each.key
  arn       = aws_lambda_function.this[each.key].arn
}

resource "aws_lambda_permission" "events" {
  for_each = local.enabled_types

  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[each.key].arn
}

###############################################################################
# Alarms — Errors + DLQ depth per Lambda
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.enabled_types

  alarm_name          = "${var.name_prefix}-idle-${each.key}-errors"
  alarm_description   = "FinOps idle-${each.key} Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this[each.key].function_name
  }

  alarm_actions = [var.events_topic_arn]
  ok_actions    = [var.events_topic_arn]
  tags          = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_dlq_depth" {
  for_each = local.enabled_types

  alarm_name          = "${var.name_prefix}-idle-${each.key}-dlq-depth"
  alarm_description   = "Messages accumulating in the idle-${each.key} Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  alarm_actions = [var.events_topic_arn]
  tags          = var.default_tags
}

###############################################################################
# Aggregate alarm — total identified monthly waste across all resource types
#
# Uses CloudWatch Metric Math to SUM(MonthlyWasteUsd) across the
# ResourceType dimension. Fires if total monthly waste exceeds the
# configurable ceiling.
###############################################################################

variable "total_waste_alarm_threshold_usd" {
  description = "Alarm if combined MonthlyWasteUsd across all resource types exceeds this value. Null disables the alarm."
  type        = number
  default     = 500
}

resource "aws_cloudwatch_metric_alarm" "total_waste" {
  count = var.total_waste_alarm_threshold_usd == null ? 0 : 1

  alarm_name          = "${var.name_prefix}-idle-total-waste"
  alarm_description   = "Total identified monthly waste across all idle-resource scans exceeded threshold — investigate the digest."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.total_waste_alarm_threshold_usd
  treat_missing_data  = "ignore"
  alarm_actions       = [var.events_topic_arn]
  ok_actions          = [var.events_topic_arn]

  metric_query {
    id          = "total"
    expression  = "SUM(METRICS())"
    label       = "Total MonthlyWasteUsd"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.enabled_types
    content {
      id = "m_${metric_query.key}"
      metric {
        namespace   = local.metric_namespace
        metric_name = "MonthlyWasteUsd"
        period      = 86400
        stat        = "Maximum"
        dimensions = {
          ResourceType = metric_query.key == "lb" ? "LoadBalancer" : (
            metric_query.key == "nat" ? "NATGateway" : (
              metric_query.key == "snapshot" ? "EBSSnapshot" : (
                metric_query.key == "eip" ? "EIP" : (
                  metric_query.key == "eni" ? "ENI" : "EBS"
                )
              )
            )
          )
        }
      }
    }
  }

  tags = var.default_tags
}

###############################################################################
# Auto-provisioned CloudWatch dashboard
#
# Single pane of glass for the FinOps lead. Six widgets:
#   - MonthlyWasteUsd line chart (per resource type)
#   - Cumulative RunSavingsUsd (sum across all types, last 6 months)
#   - FoundCount stacked area (per resource type)
#   - Top-of-mind table: most-recently-detected findings by type
#   - Lambda Errors + DLQ depth status grid
###############################################################################

resource "aws_cloudwatch_dashboard" "idle_cleanup" {
  dashboard_name = "${var.name_prefix}-idle-cleanup"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Monthly waste — by resource type"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "MonthlyWasteUsd", "ResourceType",
              k == "lb" ? "LoadBalancer" : (
                k == "nat" ? "NATGateway" : (
                  k == "snapshot" ? "EBSSnapshot" : (
                    k == "eip" ? "EIP" : (k == "eni" ? "ENI" : "EBS")
                  )
                )
              ),
            ]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Per-run savings ($/run)"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 604800, stat = "Sum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "RunSavingsUsd", "ResourceType",
              k == "lb" ? "LoadBalancer" : (
                k == "nat" ? "NATGateway" : (
                  k == "snapshot" ? "EBSSnapshot" : (
                    k == "eip" ? "EIP" : (k == "eni" ? "ENI" : "EBS")
                  )
                )
              ),
            ]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Found count over time — by resource type"
          view   = "timeSeries", stacked = true,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              local.metric_namespace, "FoundCount", "ResourceType",
              k == "lb" ? "LoadBalancer" : (
                k == "nat" ? "NATGateway" : (
                  k == "snapshot" ? "EBSSnapshot" : (
                    k == "eip" ? "EIP" : (k == "eni" ? "ENI" : "EBS")
                  )
                )
              ),
            ]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Cleanup Lambda errors (any > 0 is a problem)"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 300, stat = "Sum",
          metrics = [
            for k, _ in local.enabled_types : [
              "AWS/Lambda", "Errors", "FunctionName", "${var.name_prefix}-idle-${k}",
            ]
          ]
        }
      },
      {
        type = "text", x = 0, y = 12, width = 24, height = 2,
        properties = {
          markdown = "## Idle resource cleanup — FinOps control plane\n\nDashboard for the **idle-resource-cleanup** module. Each tile reads from CloudWatch metric namespace `${local.metric_namespace}`. The DynamoDB table `${aws_dynamodb_table.findings.name}` carries the per-resource lifecycle state (new / aging / snoozed / excepted / deleted) and the append-only audit log (`ACTION#<timestamp>` rows)."
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 24, height = 4,
        properties = {
          title  = "DLQ depth (any non-zero means failed invocations)"
          view   = "singleValue", stacked = false,
          region = data.aws_region.current.region,
          period = 300, stat = "Maximum",
          metrics = [
            for k, _ in local.enabled_types : [
              "AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName",
              "${var.name_prefix}-idle-${k}-dlq",
            ]
          ]
        }
      },
    ]
  })
}

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
