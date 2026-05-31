###############################################################################
# Lambda — daily CUR + crawler + Athena health-check
#
# Emits four metrics under FinOps/CostDataExports:
#   - CurDeliveryHours       hours since most-recent CUR file landed in S3
#   - CrawlerLastRunHours    hours since the last successful crawler run
#   - AthenaQueryability     1 if a probe query succeeds, 0 otherwise
#   - BucketObjectCount      total objects in the CUR bucket
#
# Publishes a daily digest to events_topic_arn (if provided) and surfaces
# alarms on critical thresholds.
###############################################################################

data "archive_file" "health_check" {
  count       = var.enable_health_check ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/health_check.py"
  output_path = "${path.module}/lambda/health_check.zip"
}

resource "aws_cloudwatch_log_group" "health_check" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = var.enable_health_check ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-cost-data-health"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "health_check" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  count = var.enable_health_check ? 1 : 0

  function_name                  = "${var.name_prefix}-cost-data-health"
  description                    = "Daily CUR + crawler + Athena health check"
  role                           = aws_iam_role.health_check[0].arn
  filename                       = data.archive_file.health_check[0].output_path
  source_code_hash               = data.archive_file.health_check[0].output_base64sha256
  handler                        = "health_check.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 256
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      BUCKET_NAME      = aws_s3_bucket.cost_data.id
      CRAWLER_NAME     = var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : ""
      ATHENA_WORKGROUP = var.enable_athena_workgroup ? aws_athena_workgroup.finops[0].name : ""
      ATHENA_DATABASE  = var.enable_athena_workgroup ? aws_glue_catalog_database.cur[0].name : ""
      CUR_TABLE        = var.enable_athena_workgroup ? local.cur2_table_name : ""
      SNS_TOPIC_ARN    = coalesce(var.events_topic_arn, "")
      METRIC_NAMESPACE = local.metric_namespace
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.health_check_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.health_check]
  tags       = var.default_tags
}
