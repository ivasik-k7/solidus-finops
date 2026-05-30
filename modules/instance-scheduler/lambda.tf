###############################################################################
# Lambda packaging + functions + log groups
#
# Each Lambda zip bundles a single .py file. Multi-file packaging would use
# archive_file source_dir; that's deferred until the Python code is large
# enough to need module splitting (currently 350-600 LoC per file).
###############################################################################

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

data "archive_file" "scheduler" {
  type        = "zip"
  source_file = "${path.module}/lambda/scheduler.py"
  output_path = "${path.module}/lambda/scheduler.zip"
}

data "archive_file" "discovery" {
  count       = var.enable_discovery ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/discovery.py"
  output_path = "${path.module}/lambda/discovery.zip"
}

# ---------------------------------------------------------------------------
# Log groups (CMK-encrypted)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "scheduler" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  name              = "/aws/lambda/${var.name_prefix}-scheduler"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.default_tags
}

resource "aws_cloudwatch_log_group" "discovery" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = var.enable_discovery ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-scheduler-discovery"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Lambda functions
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "scheduler" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  function_name                  = "${var.name_prefix}-scheduler"
  description                    = "Tag-driven multi-resource scheduler (EC2 + RDS + ASG). DDB-audited."
  role                           = aws_iam_role.scheduler.arn
  filename                       = data.archive_file.scheduler.output_path
  source_code_hash               = data.archive_file.scheduler.output_base64sha256
  handler                        = "scheduler.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = local.scheduler_env
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.scheduler_dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.scheduler]
  tags       = var.default_tags
}

resource "aws_lambda_function" "discovery" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled.
  count = var.enable_discovery ? 1 : 0

  function_name                  = "${var.name_prefix}-scheduler-discovery"
  description                    = "Weekly scan for low-CPU resources lacking a Schedule tag — proposes scheduling candidates."
  role                           = aws_iam_role.discovery[0].arn
  filename                       = data.archive_file.discovery[0].output_path
  source_code_hash               = data.archive_file.discovery[0].output_base64sha256
  handler                        = "discovery.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 600
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = local.discovery_env
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.discovery_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.discovery]
  tags       = var.default_tags
}
