###############################################################################
# Lambda — daily budget-performance aggregator
#
# Computes per-budget variance, burn-rate days-to-breach, fleet-wide
# BudgetAdherenceScore, and correlates breaches with current anomalies.
# Writes STATE + SNAPSHOT rows to DDB, mirrors scalars to SSM, fires a
# digest to SNS.
###############################################################################

data "archive_file" "performance" {
  count       = var.enable_performance_tracking ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/budget_performance.py"
  output_path = "${path.module}/lambda/budget_performance.zip"
}

resource "aws_cloudwatch_log_group" "performance" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = var.enable_performance_tracking ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-budget-perf"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "performance" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  count = var.enable_performance_tracking ? 1 : 0

  function_name                  = "${var.name_prefix}-budget-perf"
  description                    = "Daily FinOps budget performance: variance, burn-rate, adherence score, anomaly correlation."
  role                           = aws_iam_role.performance[0].arn
  filename                       = data.archive_file.performance[0].output_path
  source_code_hash               = data.archive_file.performance[0].output_base64sha256
  handler                        = "budget_performance.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      STATE_TABLE_NAME = aws_dynamodb_table.state[0].name
      METRIC_NAMESPACE = local.metric_namespace
      SSM_PREFIX       = local.ssm_prefix
      SNS_TOPIC_ARN    = var.events_topic_arn
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.perf_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.performance]
  tags       = var.default_tags
}
