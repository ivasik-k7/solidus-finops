###############################################################################
# IAM — per-Lambda least-privilege role
#
# Each enabled resource type gets its own role + policy composed of:
#   - The resource-specific statements from local.iam_statements
#   - Common write paths (CloudWatch metrics, SNS publish, SQS DLQ send)
#   - DDB GetItem/PutItem/Query on the findings table + its GSIs
#   - KMS Decrypt/GenerateDataKey on the framework key
#   - X-Ray PutTraceSegments / PutTelemetryRecords (conditional)
#
# Mutation actions are granted regardless of dry_run — IAM has no dry-run
# mode; the Lambda enforces dry-run at runtime via the DRY_RUN env var.
###############################################################################

resource "aws_iam_role" "this" {
  for_each = local.enabled_types

  name = "${var.name_prefix}-idle-${each.key}-role"
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

resource "aws_iam_role_policy_attachment" "basic" {
  for_each   = local.enabled_types
  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "this" {
  # checkov:skip=CKV_AWS_290: AWS does not support resource-level permissions for ec2:DeleteVolume / DeleteSnapshot / ReleaseAddress / DeleteNatGateway, elasticloadbalancing:* and similar. Scope is enforced via dry_run mode + EXCEPTION_TAG_KEY filtering at the Lambda runtime.
  # checkov:skip=CKV_AWS_355: Same as CKV_AWS_290 — these AWS actions don't accept resource-level constraints.
  for_each = local.enabled_types

  name = "${each.key}-cleanup"
  role = aws_iam_role.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.iam_statements[each.key],
      [
        { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*" },
        { Effect = "Allow", Action = ["sns:Publish"], Resource = var.events_topic_arn },
        { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq[each.key].arn },
        # DDB findings state + audit log access (scoped to the findings table
        # only, including its GSIs).
        {
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:BatchWriteItem",
          ]
          Resource = [
            aws_dynamodb_table.findings.arn,
            "${aws_dynamodb_table.findings.arn}/index/*",
          ]
        },
        # KMS perms so the Lambda can encrypt/decrypt DDB items.
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
      ],
      var.xray_tracing_enabled ? [{
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }] : [],
    )
  })
}
