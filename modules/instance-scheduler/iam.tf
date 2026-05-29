###############################################################################
# IAM — scheduler Lambda role + policy
#
# Each Lambda gets its own role. Permissions scoped to:
#   - The specific DDB table
#   - The framework KMS key
#   - The scheduler's own DLQ
#   - SNS topic (only when events_topic_arn is non-null)
#   - EC2 + RDS + ASG describe/start/stop calls
#   - CloudWatch PutMetricData (no resource-level scoping available)
###############################################################################

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-role"

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

resource "aws_iam_role_policy_attachment" "scheduler_basic" {
  role       = aws_iam_role.scheduler.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "scheduler" {
  name = "scheduler"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "ec2:DescribeInstances",
            "ec2:DescribeTags",
            "ec2:StartInstances",
            "ec2:StopInstances",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "rds:DescribeDBInstances",
            "rds:DescribeDBClusters",
            "rds:ListTagsForResource",
            "rds:StartDBInstance",
            "rds:StopDBInstance",
            "rds:StartDBCluster",
            "rds:StopDBCluster",
          ]
          Resource = "*"
        },
      ],
      var.enable_asg ? [{
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeTags",
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:CreateOrUpdateTags",
          "autoscaling:DeleteTags",
        ]
        Resource = "*"
      }] : [],
      [
        {
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:BatchWriteItem",
          ]
          Resource = aws_dynamodb_table.state.arn
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
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.scheduler_dlq.arn
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

###############################################################################
# IAM — discovery Lambda role + policy (separate, read-only)
###############################################################################

resource "aws_iam_role" "discovery" {
  count = var.enable_discovery ? 1 : 0

  name = "${var.name_prefix}-scheduler-discovery-role"

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

resource "aws_iam_role_policy_attachment" "discovery_basic" {
  count      = var.enable_discovery ? 1 : 0
  role       = aws_iam_role.discovery[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "discovery" {
  count = var.enable_discovery ? 1 : 0

  name = "discovery"
  role = aws_iam_role.discovery[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "ec2:DescribeInstances",
            "ec2:DescribeTags",
            "rds:DescribeDBInstances",
            "rds:DescribeDBClusters",
            "rds:ListTagsForResource",
          ]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricData"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.discovery_dlq[0].arn
        },
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = var.kms_key_arn
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
