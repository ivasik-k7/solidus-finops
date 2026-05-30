###############################################################################
# Lambda — KPI aggregator
###############################################################################

data "archive_file" "aggregator" {
  type        = "zip"
  source_file = "${path.module}/lambda/kpi_aggregator.py"
  output_path = "${path.module}/lambda/kpi_aggregator.zip"
}

resource "aws_cloudwatch_log_group" "aggregator" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  name              = "/aws/lambda/${var.name_prefix}-kpi-aggregator"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.default_tags
}

resource "aws_lambda_function" "aggregator" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  function_name                  = "${var.name_prefix}-kpi-aggregator"
  description                    = "Daily FinOps KPI aggregator → CloudWatch metrics + DDB snapshots + SSM + (optional) SNS digest. Manages its own dashboard."
  role                           = aws_iam_role.aggregator.arn
  filename                       = data.archive_file.aggregator.output_path
  source_code_hash               = data.archive_file.aggregator.output_base64sha256
  handler                        = "kpi_aggregator.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 600
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = local.aggregator_env
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.aggregator]
  tags       = var.default_tags
}
