###############################################################################
# Cost data exports module
#
# Provisions:
#   - S3 bucket (KMS-encrypted, versioned, lifecycle-managed) for CUR/FOCUS data
#   - CUR 2.0 export via aws_bcmdataexports_export
#   - FOCUS 1.0 export via aws_bcmdataexports_export
#   - Athena workgroup, Glue database, and Glue crawler that discovers the
#     CUR 2.0 schema and partitions
#   - TLS-only S3 bucket policy
#
# Both exports use BCM Data Exports (no legacy CUR v1, no us-east-1 alias).
###############################################################################

variable "name_prefix" { type = string }
variable "bucket_name" { type = string }
variable "kms_key_arn" { type = string }
variable "account_id"  { type = string }
variable "enable_focus_export"              { type = bool   }
variable "enable_athena_workgroup"          { type = bool   }
variable "cost_data_retention_days"  { type = number }
variable "cost_data_expiration_days" { type = number }
variable "default_tags"              { type = map(string) }

###############################################################################
# S3 bucket for cost data
###############################################################################

resource "aws_s3_bucket" "cost_data" {
  bucket = var.bucket_name

  # Belt and braces: force_destroy = false blocks `aws s3 rb` style wipes;
  # prevent_destroy below blocks `terraform destroy`. Remove both
  # intentionally if you ever need to retire the bucket.
  force_destroy = false

  tags = merge(var.default_tags, {
    Name      = var.bucket_name
    DataClass = "internal"
    Purpose   = "cost-and-usage-data"
    Retention = "7-years"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Bucket policy: allow billingreports.amazonaws.com to write CUR data,
# allow bcm-data-exports.amazonaws.com to write FOCUS data.
resource "aws_s3_bucket_policy" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id
  policy = data.aws_iam_policy_document.cost_data.json
}

data "aws_iam_policy_document" "cost_data" {
  # CUR write access for the billing reports service
  statement {
    sid    = "AllowCURWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketPolicy",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.cost_data.arn,
      "${aws_s3_bucket.cost_data.arn}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  # FOCUS / BCM Data Exports write access
  statement {
    sid    = "AllowBCMDataExportsWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com"]
    }
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketPolicy",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.cost_data.arn,
      "${aws_s3_bucket.cost_data.arn}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  # Deny any non-TLS requests
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cost_data.arn,
      "${aws_s3_bucket.cost_data.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Lifecycle strategy:
#   - Current versions tier to GLACIER_IR (Glacier Instant Retrieval) after the
#     retention window. GLACIER_IR is Athena-queryable with millisecond access
#     and ~68% cheaper than Standard. Deep Archive is NOT queryable from Athena,
#     so we never transition current versions there.
#   - Noncurrent versions (created when CUR refresh overwrites parquet files)
#     are pure audit residue, never queried directly. They go to Deep Archive
#     quickly and expire at 90 days.
#   - Current versions expire at the long retention (default 7 years, SOX/PCI).
resource "aws_s3_bucket_lifecycle_configuration" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id

  rule {
    id     = "cost-data-current-tiering"
    status = "Enabled"

    filter {} # apply to all current objects

    dynamic "transition" {
      for_each = var.cost_data_retention_days > 0 ? [1] : []
      content {
        days          = var.cost_data_retention_days
        storage_class = "GLACIER_IR"
      }
    }

    expiration {
      days = var.cost_data_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "cost-data-noncurrent-archival"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 7
      storage_class   = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

###############################################################################
# CUR 2.0 export via AWS BCM Data Exports
#
# Real CUR 2.0 — same API surface as the FOCUS export below. Unlike the
# legacy aws_cur_report_definition, this resource does NOT auto-create a
# Glue table; that's handled by the crawler defined further down.
###############################################################################

resource "aws_bcmdataexports_export" "cur2" {
  export {
    name = "${var.name_prefix}-cur2"

    data_query {
      query_statement = "SELECT * FROM COST_AND_USAGE_REPORT"

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_data.id
        s3_prefix = "cur2"
        s3_region = aws_s3_bucket.cost_data.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cost_data]
}

###############################################################################
# FOCUS 1.0 export via AWS BCM Data Exports
###############################################################################

resource "aws_bcmdataexports_export" "focus" {
  count = var.enable_focus_export ? 1 : 0

  export {
    name = "${var.name_prefix}-focus10"

    data_query {
      query_statement = "SELECT * FROM FOCUS_1_0_AWS"
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_data.id
        s3_prefix = "focus10"
        s3_region = aws_s3_bucket.cost_data.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cost_data]
}

###############################################################################
# Athena workgroup + Glue database + Glue crawler
#
# BCM Data Exports does NOT auto-create a Glue table. We provision the
# database here and a crawler that discovers the CUR 2.0 schema + partitions
# from the parquet files in S3.
#
# Operational note: the crawler runs daily; on first apply, the first CUR
# delivery happens within ~24h and the first crawler run picks it up.
# Athena queries are non-functional until both have completed (~24-48h
# after `terraform apply`).
###############################################################################

resource "aws_glue_catalog_database" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0
  name  = replace("${var.name_prefix}_cur", "-", "_")

  description = "Glue database for FinOps CUR 2.0 and FOCUS tables."
}

###############################################################################
# Glue crawler — discovers CUR 2.0 schema and partitions.
###############################################################################

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

locals {
  cur2_table_prefix = "${replace(var.name_prefix, "-", "_")}_"
  cur2_table_name   = "${local.cur2_table_prefix}data"
}

resource "aws_glue_crawler" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0

  name          = "${var.name_prefix}-cur-crawler"
  description   = "Discovers CUR 2.0 schema + partitions for Athena."
  database_name = aws_glue_catalog_database.cur[0].name
  role          = aws_iam_role.cur_crawler[0].arn

  # Deterministic table name: <namespace_env_stack>_data
  table_prefix = local.cur2_table_prefix

  # Daily at 06:00 UTC — CUR refreshes a few times a day; once is enough to
  # pick up the new BILLING_PERIOD partition when a month rolls over.
  schedule = "cron(0 6 * * ? *)"

  s3_target {
    # BCM Data Exports writes to <prefix>/<export>/<export>/data/BILLING_PERIOD=YYYY-MM/
    path = "s3://${aws_s3_bucket.cost_data.id}/cur2/${aws_bcmdataexports_export.cur2.export[0].name}/${aws_bcmdataexports_export.cur2.export[0].name}/data/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.default_tags

  depends_on = [aws_bcmdataexports_export.cur2]
}

resource "aws_s3_bucket" "athena_results" {
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = "${var.bucket_name}-athena-results"
  tags   = merge(var.default_tags, { Purpose = "athena-query-results" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = aws_s3_bucket.athena_results[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = aws_s3_bucket.athena_results[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = aws_s3_bucket.athena_results[0].id

  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_athena_workgroup" "finops" {
  count = var.enable_athena_workgroup ? 1 : 0
  name  = "${var.name_prefix}-wg"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results[0].id}/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }

  tags = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "bucket_name" {
  value = aws_s3_bucket.cost_data.id
}

output "bucket_arn" {
  value = aws_s3_bucket.cost_data.arn
}

output "cur2_export_arn" {
  description = "ARN of the CUR 2.0 BCM Data Export."
  value       = aws_bcmdataexports_export.cur2.export_arn
}

output "focus_export_arn" {
  description = "ARN of the FOCUS 1.0 BCM Data Export (null if disabled)."
  value       = var.enable_focus_export ? aws_bcmdataexports_export.focus[0].export_arn : null
}

output "athena_workgroup_name" {
  value = var.enable_athena_workgroup ? aws_athena_workgroup.finops[0].name : null
}

output "athena_database_name" {
  value = var.enable_athena_workgroup ? aws_glue_catalog_database.cur[0].name : null
}

output "cur2_table_name" {
  description = "Glue table name the crawler creates for CUR 2.0 (<namespace>_<env>_<stack>_data). Used by downstream Athena queries. Available only after the crawler's first successful run (~24-48h after first apply)."
  value       = var.enable_athena_workgroup ? local.cur2_table_name : null
}

output "cur_crawler_name" {
  description = "Glue crawler name (null if Athena workgroup disabled)."
  value       = var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : null
}
