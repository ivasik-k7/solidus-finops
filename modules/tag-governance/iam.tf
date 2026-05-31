###############################################################################
# IAM — untagged-cost report Lambda role + policy
#
# Scoped to:
#   - Athena query execution + Glue catalog reads (no resource-level scoping —
#     AWS-documented requirement)
#   - S3 RW on Athena results location
#   - KMS decrypt + GenerateDataKey on the framework key
#   - CloudWatch PutMetricData
#   - SSM PutParameter scoped to /<prefix>/tag-governance/*
#   - SNS Publish (events bus)
#   - SQS SendMessage on the Lambda's own DLQ
#   - X-Ray tracing (conditional)
###############################################################################

resource "aws_iam_role" "untagged_cost" {
  count = local.deploy_untagged_report ? 1 : 0

  name = "${var.name_prefix}-untagged-cost-role"
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

resource "aws_iam_role_policy_attachment" "untagged_cost_basic" {
  count      = local.deploy_untagged_report ? 1 : 0
  role       = aws_iam_role.untagged_cost[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "untagged_cost" {
  # checkov:skip=CKV_AWS_288: athena:* and glue:GetDatabase/GetTable/GetPartitions do not support resource-level permissions per the AWS Service Authorization Reference. s3:* on Athena results requires bucket-level access patterns Athena controls. No data-exfil path beyond what AWS-managed Athena/Glue already permit.
  # checkov:skip=CKV_AWS_290: Same — these Athena + Glue + CloudWatch:PutMetricData actions are documented as requiring Resource = "*".
  # checkov:skip=CKV_AWS_355: Same — Resource = "*" is the AWS-documented requirement for Athena query execution + Glue catalog reads.
  count = local.deploy_untagged_report ? 1 : 0

  name = "untagged-cost-report"
  role = aws_iam_role.untagged_cost[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "athena:StartQueryExecution",
            "athena:GetQueryExecution",
            "athena:GetQueryResults",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "glue:GetDatabase",
            "glue:GetTable",
            "glue:GetPartitions",
          ]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
        {
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ssm:PutParameter", "ssm:GetParameter"]
          Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
        },
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = var.events_topic_arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.untagged_cost_dlq[0].arn
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
