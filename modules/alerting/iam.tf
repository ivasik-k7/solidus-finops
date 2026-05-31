###############################################################################
# IAM — dispatcher Lambda role + policy
#
# Permissions scoped to:
#   - KMS Decrypt/GenerateDataKey on the framework key
#   - SQS SendMessage on the dispatcher's own DLQ + any caller-supplied SQS targets
#   - Secrets Manager GetSecretValue on every secret the dispatcher must read
#     (mix of module-created secrets and caller-supplied ARNs)
#   - DynamoDB GetItem/PutItem on the events table (when audit or dedup is on)
#   - CloudWatch PutMetricData (no resource-level scoping possible)
#   - X-Ray PutTraceSegments / PutTelemetryRecords (conditional)
#
# Every conditional permission is added via concat() so the policy never
# contains an empty/dangling statement.
###############################################################################

resource "aws_iam_role" "dispatcher" {
  count = local.any_dispatch_channels ? 1 : 0

  name = "${var.name_prefix}-dispatcher-role"
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

resource "aws_iam_role_policy_attachment" "dispatcher_basic" {
  count      = local.any_dispatch_channels ? 1 : 0
  role       = aws_iam_role.dispatcher[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dispatcher" {
  count = local.any_dispatch_channels ? 1 : 0

  name = "dispatcher"
  role = aws_iam_role.dispatcher[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.dispatcher_dlq[0].arn
        },
      ],
      length(local.all_secret_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.all_secret_arns
      }] : [],
      length(aws_dynamodb_table.events) > 0 ? [{
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.events[0].arn
      }] : [],
      length(local.sqs_target_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = local.sqs_target_arns
      }] : [],
      [{
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }],
      var.xray_tracing_enabled ? [{
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }] : [],
    )
  })
}
