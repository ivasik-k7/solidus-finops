###############################################################################
# Lambda — weekly untagged-cost report
#
# Dollarizes the tag gap. Deployed only when local.deploy_untagged_report
# evaluates true (requires Athena workgroup + database + at least one
# mandatory tag).
###############################################################################

data "archive_file" "untagged_cost" {
  count       = local.deploy_untagged_report ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/untagged_cost_report.py"
  output_path = "${path.module}/lambda/untagged_cost_report.zip"
}

resource "aws_cloudwatch_log_group" "untagged_cost" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = local.deploy_untagged_report ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-untagged-cost-report"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "untagged_cost" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  count = local.deploy_untagged_report ? 1 : 0

  function_name                  = "${var.name_prefix}-untagged-cost-report"
  description                    = "Weekly FinOps untagged-cost report → CloudWatch + SSM + SNS."
  role                           = aws_iam_role.untagged_cost[0].arn
  filename                       = data.archive_file.untagged_cost[0].output_path
  source_code_hash               = data.archive_file.untagged_cost[0].output_base64sha256
  handler                        = "untagged_cost_report.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 512
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      METRIC_NAMESPACE   = local.metric_namespace
      SSM_PREFIX         = local.ssm_prefix
      ATHENA_WORKGROUP   = var.athena_workgroup_name
      ATHENA_DATABASE    = var.athena_database_name
      CUR_TABLE          = var.cur_table_name
      MANDATORY_TAG_KEYS = jsonencode(local.mandatory_tag_keys)
      SNS_TOPIC_ARN      = var.events_topic_arn
      TOP_N              = tostring(var.untagged_cost_top_n)
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.untagged_cost_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.untagged_cost]
  tags       = var.default_tags
}
