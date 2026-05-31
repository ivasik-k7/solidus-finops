###############################################################################
# Lambda — six cleanup Lambdas (one per enabled resource type)
#
# Each Lambda's zip bundles:
#   - The resource-type-specific entrypoint (e.g. ebs_cleanup.py)
#   - The shared idle_state.py helper (DDB state + audit log)
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

resource "aws_cloudwatch_log_group" "this" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  for_each          = local.enabled_types
  name              = "/aws/lambda/${var.name_prefix}-idle-${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "this" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  for_each = local.enabled_types

  function_name                  = "${var.name_prefix}-idle-${each.key}"
  description                    = "Idle ${each.key} detector + (optional) cleanup. dry_run=${var.dry_run}."
  role                           = aws_iam_role.this[each.key].arn
  filename                       = data.archive_file.lambda[each.key].output_path
  source_code_hash               = data.archive_file.lambda[each.key].output_base64sha256
  handler                        = each.value.handler
  runtime                        = var.lambda_runtime
  timeout                        = each.value.timeout
  memory_size                    = each.value.memory
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = merge(local.common_env, each.value.env)
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq[each.key].arn
  }

  depends_on = [aws_cloudwatch_log_group.this]
  tags       = var.default_tags
}
