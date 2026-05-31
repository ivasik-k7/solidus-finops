###############################################################################
# Lambda — multi-channel event dispatcher
#
# Bundles two Python files (dispatcher.py + channels.py) into a single zip
# via archive_file `source` blocks. The dispatcher reads the env-var manifest
# at cold start and routes each SNS-delivered event through every matching
# channel.
###############################################################################

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
      METRIC_NAMESPACE     = local.metric_namespace
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
