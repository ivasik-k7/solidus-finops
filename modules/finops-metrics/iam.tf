###############################################################################
# IAM — aggregator Lambda role + policy
#
# Permissions scoped to:
#   - Athena query execution + result retrieval (no resource-level scoping)
#   - Glue catalog read (for the CUR table)
#   - S3 RW on the Athena results location (unscoped — Athena needs *)
#   - KMS decrypt + GenerateDataKey on the framework key
#   - Cost Explorer reads (RI/SP coverage + utilization, anomalies, forecast)
#   - CloudWatch PutMetricData + PutDashboard (rebuilds dashboard each run)
#   - SSM PutParameter scoped to /<prefix>/kpis/*
#   - SNS Publish (conditional on events_topic_arn)
#   - DynamoDB on the snapshot table only
#   - SQS SendMessage on the DLQ only
###############################################################################

resource "aws_iam_role" "aggregator" {
  name = "${var.name_prefix}-kpi-aggregator-role"

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

resource "aws_iam_role_policy_attachment" "aggregator_basic" {
  role       = aws_iam_role.aggregator.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "aggregator" {
  name = "kpi-aggregator"
  role = aws_iam_role.aggregator.id

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
            "athena:StopQueryExecution",
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
          Effect = "Allow"
          Action = [
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:PutObject",
          ]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
        },
        {
          Effect = "Allow"
          Action = [
            "ce:GetReservationCoverage",
            "ce:GetReservationUtilization",
            "ce:GetSavingsPlansCoverage",
            "ce:GetSavingsPlansUtilization",
            "ce:GetAnomalies",
            "ce:GetCostForecast",
            "ce:GetCostAndUsage",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "cloudwatch:PutMetricData",
            "cloudwatch:PutDashboard",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ssm:PutParameter",
            "ssm:GetParameter",
          ]
          Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
        },
        {
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:Query",
            "dynamodb:BatchGetItem",
            "dynamodb:BatchWriteItem",
          ]
          Resource = aws_dynamodb_table.snapshots.arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.dlq.arn
        },
      ],
      var.events_topic_arn != null ? [{
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.events_topic_arn
      }] : [],
    )
  })
}
