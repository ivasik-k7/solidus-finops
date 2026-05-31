###############################################################################
# IAM — two roles
#
#   1. budget_actions — assumed by `budgets.amazonaws.com` (only) to enforce
#      Budget Actions on threshold breach. Created only if any budget has an
#      actions block.
#   2. performance — assumed by the performance Lambda. Reads AWS Budgets,
#      Cost Explorer; writes DDB state, CloudWatch metrics, SSM, SNS, DLQ.
###############################################################################

# ---------------------------------------------------------------------------
# Budget Actions execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "budget_actions" {
  count = length(local.actions_map) > 0 ? 1 : 0

  name = "${var.name_prefix}-budget-actions-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy" "budget_actions" {
  # checkov:skip=CKV_AWS_286: AWS Budget Actions service is the only principal that can assume this role (trust policy: budgets.amazonaws.com). Budget Actions decides at runtime which specific policy/IAM target to attach based on the budget config. Privilege-escalation risk is mitigated at the trust-policy layer.
  # checkov:skip=CKV_AWS_288: Same — only budgets.amazonaws.com can use these permissions; the action types (iam:Attach*/Detach*, ec2:Stop*, rds:Stop*) are the actions AWS Budget Actions itself requires to enforce a budget breach.
  # checkov:skip=CKV_AWS_289: iam:AttachGroupPolicy etc. cannot be resource-constrained for Budget Actions because the policy ARN + target are runtime-chosen by the AWS Budget Actions service from the budget config.
  # checkov:skip=CKV_AWS_290: Same — these are the exact permissions documented by AWS as required for the Budget-Actions IAM role: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html
  # checkov:skip=CKV_AWS_355: Same — Resource = "*" is mandatory for AWS Budget Actions to fan out to the IAM/EC2/RDS/Organizations targets declared in each budget's actions block.
  count = length(local.actions_map) > 0 ? 1 : 0

  name = "budget-actions-execution"
  role = aws_iam_role.budget_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:AttachGroupPolicy",
          "iam:AttachRolePolicy",
          "iam:AttachUserPolicy",
          "iam:DetachGroupPolicy",
          "iam:DetachRolePolicy",
          "iam:DetachUserPolicy",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["organizations:AttachPolicy", "organizations:DetachPolicy"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:StartAutomationExecution", "ssm:SendCommand"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "rds:StopDBInstance", "rds:StopDBCluster"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Performance Lambda role + policy
# ---------------------------------------------------------------------------

resource "aws_iam_role" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  name = "${var.name_prefix}-budget-perf-role"
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

resource "aws_iam_role_policy_attachment" "performance_basic" {
  count      = var.enable_performance_tracking ? 1 : 0
  role       = aws_iam_role.performance[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "performance" {
  count = var.enable_performance_tracking ? 1 : 0

  name = "budget-perf"
  role = aws_iam_role.performance[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "budgets:ViewBudget",
            "budgets:DescribeBudget",
            "budgets:DescribeBudgets",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ce:GetCostAndUsage",
            "ce:GetCostForecast",
            "ce:GetAnomalies",
          ]
          Resource = "*"
        },
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
            aws_dynamodb_table.state[0].arn,
            "${aws_dynamodb_table.state[0].arn}/index/*",
          ]
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
          Resource = aws_sqs_queue.perf_dlq[0].arn
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
