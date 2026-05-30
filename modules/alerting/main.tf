###############################################################################
# Alerting module — events-bus-as-a-service
#
# A standalone, multi-channel event dispatcher. Reusable outside the FinOps
# framework: this module has no hard dependency on any other module in this
# repo. Publishers fire to the SNS topic; the dispatcher Lambda routes by
# severity to all enabled channels, deduplicates repeated alerts, and writes
# an audit trail to DynamoDB.
#
# Channels supported (each polymorphic, multiple instances per type):
#   - email          AWS SNS native; first 1k/mo free
#   - slack          Incoming webhooks; rich Block Kit cards
#   - teams          Incoming webhooks; Adaptive Cards
#   - pagerduty      Events API v2; production paging
#   - opsgenie       Alerts API; US or EU region
#   - generic_webhook  Any HTTPS endpoint (custom integrations)
#   - sqs            Queue ARN; downstream consumers pull at their pace
#
# Per-channel filtering by severity (info / low / medium / high / critical)
# lets you route critical alerts to PagerDuty while low-severity ones go to
# an info-only Slack channel.
#
# Backward compat: `notification_emails`, `slack_webhook_url`, and
# `teams_webhook_url` still work — they're synthesized into `channels` at
# module-locals time. Prefer the new `channels` schema for new deployments.
###############################################################################

###############################################################################
# Inputs
###############################################################################

variable "name_prefix" { type = string }
variable "kms_key_arn" { type = string }

variable "log_retention_days" {
  type    = number
  default = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338 — and most audit regimes require 1y+). Drop the variable in your root composition if you really need less."
  }
}

variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "default_tags" {
  type    = map(string)
  default = {}
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the dispatcher Lambda. Adds the IAM permissions + the tracing_config block. ~$0.0001 per 100k traces — effectively free at this volume."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the dispatcher Lambda. Null = no reservation (default). Set to a positive integer to cap concurrency, or -1 to disable invocations entirely."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Legacy inputs (synthesised into `channels` if `channels` is empty)
# ---------------------------------------------------------------------------

variable "notification_emails" {
  description = "Legacy: emails for SNS subscription. Prefer channels.email."
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Legacy single-Slack-webhook. Prefer channels.slack."
  type        = string
  default     = null
  sensitive   = true
}

variable "teams_webhook_url" {
  description = "Legacy single-Teams-webhook. Prefer channels.teams."
  type        = string
  default     = null
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Multi-channel polymorphic schema
# ---------------------------------------------------------------------------

variable "channels" {
  description = <<-EOT
    Multi-channel destination configuration. Each channel-type list holds 0+
    destinations, each with its own min_severity filter.

    Severities (ascending): info | low | medium | high | critical
    A channel with min_severity = "high" only receives alerts of severity
    high or critical.

    For each destination you can pass either:
      - the inline secret value (webhook_url, integration_key, api_key) —
        the module will create a Secrets Manager secret and reference its ARN
      - or *_secret_arn — point at an existing secret you manage elsewhere

    Example:
      channels = {
        slack = [
          { webhook_url = "https://hooks.slack.com/services/...", label = "#finops",       min_severity = "info" },
          { webhook_url = "https://hooks.slack.com/services/...", label = "#incidents",    min_severity = "high" },
        ]
        pagerduty = [
          { integration_key = "abc...", label = "finops-oncall", min_severity = "high" },
        ]
        email = [
          { addresses = ["finops@example.com"], min_severity = "info" },
        ]
      }
  EOT
  type = object({
    email = optional(list(object({
      addresses    = list(string)
      min_severity = optional(string, "info")
    })), [])

    slack = optional(list(object({
      webhook_url        = optional(string)
      webhook_secret_arn = optional(string)
      label              = optional(string, "slack")
      min_severity       = optional(string, "info")
    })), [])

    teams = optional(list(object({
      webhook_url        = optional(string)
      webhook_secret_arn = optional(string)
      label              = optional(string, "teams")
      min_severity       = optional(string, "info")
    })), [])

    pagerduty = optional(list(object({
      integration_key            = optional(string)
      integration_key_secret_arn = optional(string)
      label                      = optional(string, "pagerduty")
      min_severity               = optional(string, "high")
    })), [])

    opsgenie = optional(list(object({
      api_key            = optional(string)
      api_key_secret_arn = optional(string)
      label              = optional(string, "opsgenie")
      eu_region          = optional(bool, false)
      min_severity       = optional(string, "high")
    })), [])

    generic_webhooks = optional(list(object({
      url            = optional(string)
      url_secret_arn = optional(string)
      label          = string
      headers        = optional(map(string), {})
      min_severity   = optional(string, "info")
    })), [])

    sqs = optional(list(object({
      queue_arn    = string
      label        = optional(string, "sqs")
      min_severity = optional(string, "info")
    })), [])
  })
  default = {}

  validation {
    condition = alltrue(concat(
      [for c in coalesce(var.channels.slack, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.teams, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.pagerduty, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.opsgenie, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.email, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.generic_webhooks, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
      [for c in coalesce(var.channels.sqs, []) : contains(["info", "low", "medium", "high", "critical"], c.min_severity)],
    ))
    error_message = "channels.*.min_severity must be one of: info, low, medium, high, critical."
  }
}

# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

variable "deduplication" {
  description = <<-EOT
    Deduplication cache config. When two events with the same fingerprint
    land within `window_minutes`, the second is suppressed (still audited).
  EOT
  type = object({
    enabled            = optional(bool, true)
    window_minutes     = optional(number, 60)
    fingerprint_fields = optional(list(string), ["AlertName", "severity", "ResourceId"])
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

variable "audit_log" {
  description = "Audit log config (DDB-backed). Records every dispatched event + outcome per channel."
  type = object({
    enabled        = optional(bool, true)
    retention_days = optional(number, 365)
  })
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

###############################################################################
# Local — synthesise legacy inputs into `channels`, flatten for resources
###############################################################################

locals {
  # Legacy → new bridge. Only used when `channels` is empty.
  legacy_channels = {
    email = length(var.notification_emails) > 0 ? [
      { addresses = var.notification_emails, min_severity = "info" }
    ] : []
    slack = var.slack_webhook_url == null ? [] : [
      { webhook_url = var.slack_webhook_url, label = "slack-legacy", min_severity = "info", webhook_secret_arn = null }
    ]
    teams = var.teams_webhook_url == null ? [] : [
      { webhook_url = var.teams_webhook_url, label = "teams-legacy", min_severity = "info", webhook_secret_arn = null }
    ]
    pagerduty        = []
    opsgenie         = []
    generic_webhooks = []
    sqs              = []
  }

  channels_empty = (
    length(coalesce(var.channels.email, [])) == 0 &&
    length(coalesce(var.channels.slack, [])) == 0 &&
    length(coalesce(var.channels.teams, [])) == 0 &&
    length(coalesce(var.channels.pagerduty, [])) == 0 &&
    length(coalesce(var.channels.opsgenie, [])) == 0 &&
    length(coalesce(var.channels.generic_webhooks, [])) == 0 &&
    length(coalesce(var.channels.sqs, [])) == 0
  )

  effective_channels = local.channels_empty ? local.legacy_channels : {
    email            = coalesce(var.channels.email, [])
    slack            = coalesce(var.channels.slack, [])
    teams            = coalesce(var.channels.teams, [])
    pagerduty        = coalesce(var.channels.pagerduty, [])
    opsgenie         = coalesce(var.channels.opsgenie, [])
    generic_webhooks = coalesce(var.channels.generic_webhooks, [])
    sqs              = coalesce(var.channels.sqs, [])
  }

  # Email destinations expanded to one (channel × address) pair per row.
  email_subscriptions = flatten([
    for ch in local.effective_channels.email : [
      for addr in ch.addresses : { address = addr, min_severity = ch.min_severity }
    ]
  ])

  # Channels needing a Secrets Manager secret (inline value provided).
  slack_inline_secrets = {
    for idx, ch in local.effective_channels.slack :
    "slack-${idx}" => ch if ch.webhook_url != null
  }
  teams_inline_secrets = {
    for idx, ch in local.effective_channels.teams :
    "teams-${idx}" => ch if ch.webhook_url != null
  }
  pagerduty_inline_secrets = {
    for idx, ch in local.effective_channels.pagerduty :
    "pagerduty-${idx}" => ch if ch.integration_key != null
  }
  opsgenie_inline_secrets = {
    for idx, ch in local.effective_channels.opsgenie :
    "opsgenie-${idx}" => ch if ch.api_key != null
  }
  webhook_inline_secrets = {
    for idx, ch in local.effective_channels.generic_webhooks :
    "webhook-${idx}" => ch if ch.url != null
  }

  any_dispatch_channels = (
    length(local.effective_channels.slack) > 0 ||
    length(local.effective_channels.teams) > 0 ||
    length(local.effective_channels.pagerduty) > 0 ||
    length(local.effective_channels.opsgenie) > 0 ||
    length(local.effective_channels.generic_webhooks) > 0 ||
    length(local.effective_channels.sqs) > 0
  )

  # Dispatcher consumes a "manifest" — all channels + their resolved secret
  # ARNs — as a JSON env var.
  dispatcher_manifest = jsonencode({
    slack = [
      for idx, ch in local.effective_channels.slack : {
        label              = ch.label
        min_severity       = ch.min_severity
        webhook_secret_arn = ch.webhook_url != null ? aws_secretsmanager_secret.slack[tostring(idx)].arn : ch.webhook_secret_arn
      }
    ]
    teams = [
      for idx, ch in local.effective_channels.teams : {
        label              = ch.label
        min_severity       = ch.min_severity
        webhook_secret_arn = ch.webhook_url != null ? aws_secretsmanager_secret.teams[tostring(idx)].arn : ch.webhook_secret_arn
      }
    ]
    pagerduty = [
      for idx, ch in local.effective_channels.pagerduty : {
        label                      = ch.label
        min_severity               = ch.min_severity
        integration_key_secret_arn = ch.integration_key != null ? aws_secretsmanager_secret.pagerduty[tostring(idx)].arn : ch.integration_key_secret_arn
      }
    ]
    opsgenie = [
      for idx, ch in local.effective_channels.opsgenie : {
        label              = ch.label
        min_severity       = ch.min_severity
        eu_region          = ch.eu_region
        api_key_secret_arn = ch.api_key != null ? aws_secretsmanager_secret.opsgenie[tostring(idx)].arn : ch.api_key_secret_arn
      }
    ]
    generic_webhooks = [
      for idx, ch in local.effective_channels.generic_webhooks : {
        label          = ch.label
        min_severity   = ch.min_severity
        headers        = ch.headers
        url_secret_arn = ch.url != null ? aws_secretsmanager_secret.webhook[tostring(idx)].arn : ch.url_secret_arn
      }
    ]
    sqs = [
      for ch in local.effective_channels.sqs : {
        label        = ch.label
        min_severity = ch.min_severity
        queue_arn    = ch.queue_arn
      }
    ]
  })

  # All secret ARNs the dispatcher must read at runtime.
  all_secret_arns = concat(
    [for s in aws_secretsmanager_secret.slack : s.arn],
    [for s in aws_secretsmanager_secret.teams : s.arn],
    [for s in aws_secretsmanager_secret.pagerduty : s.arn],
    [for s in aws_secretsmanager_secret.opsgenie : s.arn],
    [for s in aws_secretsmanager_secret.webhook : s.arn],
    [for ch in local.effective_channels.slack : ch.webhook_secret_arn if ch.webhook_secret_arn != null],
    [for ch in local.effective_channels.teams : ch.webhook_secret_arn if ch.webhook_secret_arn != null],
    [for ch in local.effective_channels.pagerduty : ch.integration_key_secret_arn if ch.integration_key_secret_arn != null],
    [for ch in local.effective_channels.opsgenie : ch.api_key_secret_arn if ch.api_key_secret_arn != null],
    [for ch in local.effective_channels.generic_webhooks : ch.url_secret_arn if ch.url_secret_arn != null],
  )

  sqs_target_arns = [for ch in local.effective_channels.sqs : ch.queue_arn]
}

###############################################################################
# SNS topic — the events bus
###############################################################################

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = var.default_tags
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "AllowAccountOwners"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
    actions   = ["SNS:Publish", "SNS:Subscribe"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowAWSServicePublishers"
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "budgets.amazonaws.com",
        "costalerts.amazonaws.com",
        "events.amazonaws.com",
        "cloudwatch.amazonaws.com",
      ]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

###############################################################################
# Email subscriptions (one per address, native SNS — no Lambda hop)
###############################################################################

resource "aws_sns_topic_subscription" "email" {
  for_each = { for s in local.email_subscriptions : s.address => s }

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value.address
}

###############################################################################
# Secrets Manager — one secret per inline-supplied webhook / key
###############################################################################

resource "aws_secretsmanager_secret" "slack" {
  # checkov:skip=CKV2_AWS_57: Slack incoming webhook URLs are immutable — Slack does not support webhook URL rotation. Rotation must be initiated by the Slack workspace admin via the Slack UI; AWS Secrets Manager cannot perform this. Operators rotate manually when needed.
  # Iterate the non-sensitive key set so tflint's static evaluator doesn't choke.
  # Look the sensitive value up from the map by key inside the resource body.
  for_each = nonsensitive(toset(keys(local.slack_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Slack webhook for channel '${local.slack_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "slack" {
  for_each      = nonsensitive(toset(keys(local.slack_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.slack[each.value].id
  secret_string = local.slack_inline_secrets[each.value].webhook_url
}

resource "aws_secretsmanager_secret" "teams" {
  # checkov:skip=CKV2_AWS_57: Microsoft Teams incoming webhook URLs are immutable — Teams does not support webhook rotation via an API. Operators rotate manually via Teams admin.
  for_each = nonsensitive(toset(keys(local.teams_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Teams webhook for channel '${local.teams_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "teams" {
  for_each      = nonsensitive(toset(keys(local.teams_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.teams[each.value].id
  secret_string = local.teams_inline_secrets[each.value].webhook_url
}

resource "aws_secretsmanager_secret" "pagerduty" {
  # checkov:skip=CKV2_AWS_57: PagerDuty integration keys are static credentials managed in the PagerDuty UI. Rotation requires re-issuing the integration on the PagerDuty side — not something AWS Secrets Manager can automate.
  for_each = nonsensitive(toset(keys(local.pagerduty_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "PagerDuty integration key for channel '${local.pagerduty_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "pagerduty" {
  for_each      = nonsensitive(toset(keys(local.pagerduty_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.pagerduty[each.value].id
  secret_string = local.pagerduty_inline_secrets[each.value].integration_key
}

resource "aws_secretsmanager_secret" "opsgenie" {
  # checkov:skip=CKV2_AWS_57: Opsgenie API keys are static credentials issued from the Opsgenie integration UI — no AWS-Secrets-Manager-driven rotation API exists on the Opsgenie side.
  for_each = nonsensitive(toset(keys(local.opsgenie_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Opsgenie API key for channel '${local.opsgenie_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "opsgenie" {
  for_each      = nonsensitive(toset(keys(local.opsgenie_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.opsgenie[each.value].id
  secret_string = local.opsgenie_inline_secrets[each.value].api_key
}

resource "aws_secretsmanager_secret" "webhook" {
  # checkov:skip=CKV2_AWS_57: Generic webhook URLs are caller-defined opaque strings — the framework has no knowledge of how to rotate them. Operators rotate manually when the downstream service issues a new URL.
  for_each = nonsensitive(toset(keys(local.webhook_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Generic webhook URL for channel '${local.webhook_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "webhook" {
  for_each      = nonsensitive(toset(keys(local.webhook_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.webhook[each.value].id
  secret_string = local.webhook_inline_secrets[each.value].url
}

###############################################################################
# DynamoDB — audit log + dedup cache (single table)
#
# PK = "DEDUP#<fingerprint-sha>"  →  short-TTL row, cache for suppression
# PK = "AUDIT#<iso-ts>-<random>"  →  audit log row for each dispatched event
###############################################################################

resource "aws_dynamodb_table" "events" {
  count = (var.audit_log.enabled != false || var.deduplication.enabled != false) ? 1 : 0

  name         = "${var.name_prefix}-alerting-events"
  billing_mode = "PAY_PER_REQUEST"
  # NOTE: hash_key/range_key are deprecated in favor of key_schema in newer
  # AWS provider versions, but the replacement syntax is still in flux.
  # Apply works fine with the deprecation warning. Migrate when stable.
  hash_key = "PK"

  attribute {
    name = "PK"
    type = "S"
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
# Dispatcher Lambda — replaces the old chat-notifier
###############################################################################

resource "aws_sqs_queue" "dispatcher_dlq" {
  count = local.any_dispatch_channels ? 1 : 0

  name                      = "${var.name_prefix}-dispatcher-dlq"
  message_retention_seconds = 1209600 # 14d
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}

resource "aws_iam_role" "dispatcher" {
  count = local.any_dispatch_channels ? 1 : 0

  name = "${var.name_prefix}-dispatcher-role"
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

resource "aws_iam_role_policy_attachment" "dispatcher_basic" {
  count      = local.any_dispatch_channels ? 1 : 0
  role       = aws_iam_role.dispatcher[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dispatcher" {
  count = local.any_dispatch_channels ? 1 : 0

  name = "dispatcher"
  role = aws_iam_role.dispatcher[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.dispatcher_dlq[0].arn
        },
      ],
      length(local.all_secret_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.all_secret_arns
      }] : [],
      length(aws_dynamodb_table.events) > 0 ? [{
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.events[0].arn
      }] : [],
      length(local.sqs_target_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = local.sqs_target_arns
      }] : [],
      [{
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }],
      var.xray_tracing_enabled ? [{
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }] : [],
    )
  })
}

data "archive_file" "dispatcher" {
  count       = local.any_dispatch_channels ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/lambda/dispatcher.zip"

  source {
    content  = file("${path.module}/lambda/dispatcher.py")
    filename = "dispatcher.py"
  }

  source {
    content  = file("${path.module}/lambda/channels.py")
    filename = "channels.py"
  }
}

resource "aws_cloudwatch_log_group" "dispatcher" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, which has a `>= 365` validation block. Static analysers can't evaluate variable validations; the constraint is enforced at terraform plan time.
  count             = local.any_dispatch_channels ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-dispatcher"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "dispatcher" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer infrastructure (signing profile + signing config). Enterprise opt-in not modelled. Pin a specific Terraform module ref/commit for supply-chain protection instead.
  count = local.any_dispatch_channels ? 1 : 0

  function_name                  = "${var.name_prefix}-dispatcher"
  description                    = "Multi-channel event dispatcher with severity routing + dedup + audit"
  role                           = aws_iam_role.dispatcher[0].arn
  filename                       = data.archive_file.dispatcher[0].output_path
  source_code_hash               = data.archive_file.dispatcher[0].output_base64sha256
  handler                        = "dispatcher.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 30
  memory_size                    = 256
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      CHANNEL_MANIFEST     = local.dispatcher_manifest
      DEDUP_ENABLED        = tostring(coalesce(var.deduplication.enabled, true))
      DEDUP_WINDOW_MINS    = tostring(coalesce(var.deduplication.window_minutes, 60))
      DEDUP_FINGERPRINT    = jsonencode(coalesce(var.deduplication.fingerprint_fields, ["AlertName", "severity", "ResourceId"]))
      AUDIT_ENABLED        = tostring(coalesce(var.audit_log.enabled, true))
      AUDIT_RETENTION_DAYS = tostring(coalesce(var.audit_log.retention_days, 365))
      EVENTS_TABLE_NAME    = length(aws_dynamodb_table.events) > 0 ? aws_dynamodb_table.events[0].name : ""
      METRIC_NAMESPACE     = "FinOps/Alerting"
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dispatcher_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.dispatcher]
  tags       = var.default_tags
}

resource "aws_lambda_permission" "dispatcher_sns" {
  count         = local.any_dispatch_channels ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "dispatcher" {
  count     = local.any_dispatch_channels ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.dispatcher[0].arn
}

###############################################################################
# Alarms on the dispatcher itself
###############################################################################

resource "aws_cloudwatch_metric_alarm" "dispatcher_errors" {
  count = local.any_dispatch_channels ? 1 : 0

  alarm_name          = "${var.name_prefix}-dispatcher-errors"
  alarm_description   = "Event dispatcher Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.dispatcher[0].function_name }
  # Note: This alarm cannot publish back to the same SNS topic the dispatcher
  # consumes (would loop). It's a CloudWatch-only alarm; subscribers can
  # discover it via DescribeAlarms or watch for the metric directly.
  tags = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "dispatcher_dlq_depth" {
  count = local.any_dispatch_channels ? 1 : 0

  alarm_name          = "${var.name_prefix}-dispatcher-dlq-depth"
  alarm_description   = "Messages accumulating in the event dispatcher DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.dispatcher_dlq[0].name }
  tags                = var.default_tags
}

###############################################################################
# Outputs — the standalone-friendly contract
###############################################################################

output "events_topic_arn" {
  description = "ARN of the SNS topic publishers should write to."
  value       = aws_sns_topic.alerts.arn
}

output "events_topic_name" {
  description = "Name of the SNS topic."
  value       = aws_sns_topic.alerts.name
}

output "dispatcher_lambda_arn" {
  description = "Dispatcher Lambda ARN (null if no dispatch channels configured)."
  value       = local.any_dispatch_channels ? aws_lambda_function.dispatcher[0].arn : null
}

output "dispatcher_dlq_arn" {
  description = "Dispatcher DLQ ARN."
  value       = local.any_dispatch_channels ? aws_sqs_queue.dispatcher_dlq[0].arn : null
}

output "events_table_name" {
  description = "DynamoDB table for audit log + dedup cache."
  value       = length(aws_dynamodb_table.events) > 0 ? aws_dynamodb_table.events[0].name : null
}

output "channel_secret_arns" {
  description = "Map of channel-key → Secrets Manager ARN (for channels where the inline URL/key was provided)."
  value = merge(
    { for k, s in aws_secretsmanager_secret.slack : k => s.arn },
    { for k, s in aws_secretsmanager_secret.teams : k => s.arn },
    { for k, s in aws_secretsmanager_secret.pagerduty : k => s.arn },
    { for k, s in aws_secretsmanager_secret.opsgenie : k => s.arn },
    { for k, s in aws_secretsmanager_secret.webhook : k => s.arn },
  )
}

# Backward-compat output names (so root main.tf doesn't break).
output "chat_notifier_lambda_arn" {
  description = "Backward-compat alias of dispatcher_lambda_arn."
  value       = local.any_dispatch_channels ? aws_lambda_function.dispatcher[0].arn : null
}

output "chat_notifier_dlq_arn" {
  description = "Backward-compat alias of dispatcher_dlq_arn."
  value       = local.any_dispatch_channels ? aws_sqs_queue.dispatcher_dlq[0].arn : null
}

output "slack_webhook_secret_arn" {
  description = "Backward-compat: first Slack channel's secret ARN (null if none)."
  value       = length(aws_secretsmanager_secret.slack) > 0 ? values(aws_secretsmanager_secret.slack)[0].arn : null
}

output "teams_webhook_secret_arn" {
  description = "Backward-compat: first Teams channel's secret ARN (null if none)."
  value       = length(aws_secretsmanager_secret.teams) > 0 ? values(aws_secretsmanager_secret.teams)[0].arn : null
}
