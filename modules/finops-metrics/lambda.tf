###############################################################################
# Lambda — KPI aggregator
###############################################################################

data "archive_file" "aggregator" {
  type        = "zip"
  source_file = "${path.module}/lambda/kpi_aggregator.py"
  output_path = "${path.module}/lambda/kpi_aggregator.zip"
}

resource "aws_cloudwatch_log_group" "aggregator" {
  name              = "/aws/lambda/${var.name_prefix}-kpi-aggregator"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.default_tags
}

resource "aws_lambda_function" "aggregator" {
  function_name    = "${var.name_prefix}-kpi-aggregator"
  description      = "Daily FinOps KPI aggregator → CloudWatch metrics + DDB snapshots + SSM + (optional) SNS digest. Manages its own dashboard."
  role             = aws_iam_role.aggregator.arn
  filename         = data.archive_file.aggregator.output_path
  source_code_hash = data.archive_file.aggregator.output_base64sha256
  handler          = "kpi_aggregator.handler"
  runtime          = var.lambda_runtime
  timeout          = 600
  memory_size      = 512
  kms_key_arn      = var.kms_key_arn

  environment {
    variables = local.aggregator_env
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.aggregator]
  tags       = var.default_tags
}
