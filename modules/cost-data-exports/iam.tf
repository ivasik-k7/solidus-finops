###############################################################################
# IAM — three role classes
#
#   1. cur_crawler            assumed by glue.amazonaws.com to discover the
#                             CUR schema; reads cur2/ prefix + KMS Decrypt.
#   2. cross_account_reader   one per entry in var.cross_account_readers;
#                             foreign-account trust + read-only access.
#   3. health_check           assumed by the health-check Lambda; reads CUR
#                             bucket + Glue catalog + (optional) Athena.
###############################################################################

# ---------------------------------------------------------------------------
# CUR crawler role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cur_crawler" {
  count = var.enable_athena_workgroup ? 1 : 0

  name = "${var.name_prefix}-cur-crawler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "cur_crawler_service" {
  count      = var.enable_athena_workgroup ? 1 : 0
  role       = aws_iam_role.cur_crawler[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "cur_crawler" {
  count = var.enable_athena_workgroup ? 1 : 0

  name = "cur-crawler"
  role = aws_iam_role.cur_crawler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.cost_data.arn,
          "${aws_s3_bucket.cost_data.arn}/cur2/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Cross-account reader roles — one per entry in var.cross_account_readers
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cross_account_reader" {
  for_each = { for r in var.cross_account_readers : r.name => r }

  name = coalesce(each.value.role_name, "${var.name_prefix}-${each.value.name}-reader")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${each.value.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = each.value.external_id != null ? {
        StringEquals = { "sts:ExternalId" = each.value.external_id }
      } : {}
    }]
  })

  tags = merge(var.default_tags, {
    Purpose          = "3rd-party FinOps tool reader"
    ReaderName       = each.value.name
    TrustedAccountId = each.value.account_id
  })
}

resource "aws_iam_role_policy" "cross_account_reader" {
  for_each = { for r in var.cross_account_readers : r.name => r }

  name = "read-cost-data"
  role = aws_iam_role.cross_account_reader[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:GetObject",
          ]
          Resource = [
            aws_s3_bucket.cost_data.arn,
            "${aws_s3_bucket.cost_data.arn}/*",
          ]
        },
        {
          Effect = "Allow"
          Action = [
            "glue:GetDatabase",
            "glue:GetDatabases",
            "glue:GetTable",
            "glue:GetTables",
            "glue:GetPartition",
            "glue:GetPartitions",
          ]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.kms_key_arn
        },
      ],
      each.value.enable_athena && var.enable_athena_workgroup ? [
        {
          Effect = "Allow"
          Action = [
            "athena:StartQueryExecution",
            "athena:GetQueryExecution",
            "athena:GetQueryResults",
            "athena:GetWorkGroup",
            "athena:ListWorkGroups",
          ]
          Resource = aws_athena_workgroup.finops[0].arn
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject"]
          Resource = "${aws_s3_bucket.athena_results[0].arn}/*"
        },
      ] : []
    )
  })
}

# ---------------------------------------------------------------------------
# Health-check Lambda role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "health_check" {
  count = var.enable_health_check ? 1 : 0

  name = "${var.name_prefix}-cost-data-health-role"
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

resource "aws_iam_role_policy_attachment" "health_check_basic" {
  count      = var.enable_health_check ? 1 : 0
  role       = aws_iam_role.health_check[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "health_check" {
  count = var.enable_health_check ? 1 : 0

  name = "health-check"
  role = aws_iam_role.health_check[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:GetObject"]
          Resource = [aws_s3_bucket.cost_data.arn, "${aws_s3_bucket.cost_data.arn}/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["glue:GetCrawler", "glue:GetDatabase", "glue:GetTable"]
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
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.health_check_dlq[0].arn
        },
      ],
      var.events_topic_arn != null ? [{
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.events_topic_arn
      }] : [],
      var.enable_athena_workgroup ? [
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
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject"]
          Resource = "${aws_s3_bucket.athena_results[0].arn}/*"
        },
      ] : [],
      var.xray_tracing_enabled ? [{
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }] : [],
    )
  })
}
