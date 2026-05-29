###############################################################################
# Alerting module
#
# Provides a single SNS topic that ALL FinOps modules publish to.
# Optionally fans out to Slack and/or Teams via Lambda.
#
# Design notes:
#   - One topic, many channels — keeps governance simple.
#   - KMS-encrypted topic — banking-grade.
#   - Lambda log groups encrypted with the same key.
#   - 7-year log retention default.
###############################################################################

variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "notification_emails" {
  type    = list(string)
  default = []
}

variable "slack_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "teams_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "log_retention_days" {
  type    = number
  default = 2557
}

variable "lambda_runtime" {
  type = string
}

variable "default_tags" {
  type    = map(string)
  default = {}
}

###############################################################################
# SNS topic
###############################################################################

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = var.default_tags
}

# Allow the AWS services that publish events (Budgets, Cost Anomaly Detection,
# EventBridge, CloudWatch) to publish to this topic.
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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

###############################################################################
# Email subscriptions
###############################################################################

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

###############################################################################
# Slack / Teams notifier Lambda
#
# A single Lambda handles both Slack and Teams. Webhooks are passed as
# encrypted environment variables; the function picks the right adapter
# per message.
###############################################################################

locals {
  deploy_chat_notifier = var.slack_webhook_url != null || var.teams_webhook_url != null
}

###############################################################################
# Webhook URLs in Secrets Manager
#
# Webhooks are write-once, read-at-runtime. Storing them in Secrets Manager
# (KMS-encrypted with the framework CMK) gives:
#   - rotation hooks (you can rotate the URL without redeploying the Lambda)
#   - auditable access via CloudTrail data events
#   - separation between IaC state and the secret material itself
#
# A 30-day recovery window protects against accidental destroy.
###############################################################################

resource "aws_secretsmanager_secret" "slack_webhook" {
  count = var.slack_webhook_url == null ? 0 : 1

  name                    = "${var.name_prefix}-slack-webhook-url"
  description             = "Slack incoming webhook URL for the FinOps chat-notifier Lambda."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30

  tags = var.default_tags
}

resource "aws_secretsmanager_secret_version" "slack_webhook" {
  count = var.slack_webhook_url == null ? 0 : 1

  secret_id     = aws_secretsmanager_secret.slack_webhook[0].id
  secret_string = var.slack_webhook_url
}

resource "aws_secretsmanager_secret" "teams_webhook" {
  count = var.teams_webhook_url == null ? 0 : 1

  name                    = "${var.name_prefix}-teams-webhook-url"
  description             = "Microsoft Teams incoming webhook URL for the FinOps chat-notifier Lambda."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30

  tags = var.default_tags
}

resource "aws_secretsmanager_secret_version" "teams_webhook" {
  count = var.teams_webhook_url == null ? 0 : 1

  secret_id     = aws_secretsmanager_secret.teams_webhook[0].id
  secret_string = var.teams_webhook_url
}

data "archive_file" "chat_notifier" {
  count       = local.deploy_chat_notifier ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/chat_notifier.py"
  output_path = "${path.module}/lambda/chat_notifier.zip"
}

resource "aws_iam_role" "chat_notifier" {
  count = local.deploy_chat_notifier ? 1 : 0

  name = "${var.name_prefix}-chat-notifier-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "chat_notifier_basic" {
  count      = local.deploy_chat_notifier ? 1 : 0
  role       = aws_iam_role.chat_notifier[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

locals {
  webhook_secret_arns = compact([
    var.slack_webhook_url == null ? null : try(aws_secretsmanager_secret.slack_webhook[0].arn, null),
    var.teams_webhook_url == null ? null : try(aws_secretsmanager_secret.teams_webhook[0].arn, null),
  ])
}

# KMS permission so the Lambda can decrypt secret values.
# SecretsManager permission scoped to the framework's two webhook secrets.
# SQS DLQ permission so failed invocations route to the dead-letter queue.
resource "aws_iam_role_policy" "chat_notifier_inline" {
  count = local.deploy_chat_notifier ? 1 : 0
  name  = "chat-notifier-inline"
  role  = aws_iam_role.chat_notifier[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.webhook_secret_arns
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.chat_notifier_dlq[0].arn
      },
    ]
  })
}

###############################################################################
# Dead-letter queue for failed chat-notifier invocations.
###############################################################################

resource "aws_sqs_queue" "chat_notifier_dlq" {
  count = local.deploy_chat_notifier ? 1 : 0

  name                      = "${var.name_prefix}-chat-notifier-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.default_tags
}

resource "aws_cloudwatch_log_group" "chat_notifier" {
  count             = local.deploy_chat_notifier ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-chat-notifier"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "chat_notifier" {
  count = local.deploy_chat_notifier ? 1 : 0

  function_name    = "${var.name_prefix}-chat-notifier"
  description      = "Forwards FinOps SNS alerts to Slack and/or Teams"
  role             = aws_iam_role.chat_notifier[0].arn
  filename         = data.archive_file.chat_notifier[0].output_path
  source_code_hash = data.archive_file.chat_notifier[0].output_base64sha256
  handler          = "chat_notifier.handler"
  runtime          = var.lambda_runtime
  timeout          = 30
  memory_size      = 256

  kms_key_arn = var.kms_key_arn

  environment {
    variables = {
      # Lambda receives ARNs, not URLs. The Python code resolves them at
      # runtime via Secrets Manager and caches the values per warm container.
      SLACK_WEBHOOK_SECRET_ARN = var.slack_webhook_url == null ? "" : aws_secretsmanager_secret.slack_webhook[0].arn
      TEAMS_WEBHOOK_SECRET_ARN = var.teams_webhook_url == null ? "" : aws_secretsmanager_secret.teams_webhook[0].arn
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.chat_notifier_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.chat_notifier]
  tags       = var.default_tags
}

###############################################################################
# CloudWatch alarms on the chat-notifier Lambda.
#
# Both fire to the events topic. If the chat notifier itself is the failure
# point, email subscribers still receive the alarm directly from SNS.
#
# Note on the apparent cycle: the chat-notifier subscribes to this same topic
# AND its error alarm publishes to it. This is not an infinite loop —
# CloudWatch alarms only fire on state transitions (OK → ALARM, ALARM → OK),
# not continuously. A broken notifier produces a single alarm message that
# fails to deliver and lands in the notifier's own DLQ; email subscribers
# still receive the alarm via direct SNS delivery.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "chat_notifier_errors" {
  count = local.deploy_chat_notifier ? 1 : 0

  alarm_name          = "${var.name_prefix}-chat-notifier-errors"
  alarm_description   = "FinOps chat-notifier Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.chat_notifier[0].function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "chat_notifier_dlq_depth" {
  count = local.deploy_chat_notifier ? 1 : 0

  alarm_name          = "${var.name_prefix}-chat-notifier-dlq-depth"
  alarm_description   = "Messages accumulating in the chat-notifier Lambda DLQ."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.chat_notifier_dlq[0].name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = var.default_tags
}

resource "aws_lambda_permission" "chat_notifier_sns" {
  count         = local.deploy_chat_notifier ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_notifier[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "chat_notifier" {
  count     = local.deploy_chat_notifier ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chat_notifier[0].arn
}

###############################################################################
# Outputs
###############################################################################

output "events_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "events_topic_name" {
  value = aws_sns_topic.alerts.name
}

output "chat_notifier_lambda_arn" {
  value = local.deploy_chat_notifier ? aws_lambda_function.chat_notifier[0].arn : null
}

output "chat_notifier_dlq_arn" {
  value = local.deploy_chat_notifier ? aws_sqs_queue.chat_notifier_dlq[0].arn : null
}

output "slack_webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Slack webhook URL (null if not configured)."
  value       = var.slack_webhook_url == null ? null : aws_secretsmanager_secret.slack_webhook[0].arn
}

output "teams_webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Teams webhook URL (null if not configured)."
  value       = var.teams_webhook_url == null ? null : aws_secretsmanager_secret.teams_webhook[0].arn
}
