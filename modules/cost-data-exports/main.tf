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
variable "account_id" { type = string }
variable "enable_focus_export" { type = bool }
variable "enable_athena_workgroup" { type = bool }
variable "cost_data_retention_days" { type = number }
variable "cost_data_expiration_days" { type = number }
variable "default_tags" { type = map(string) }

# ---------------------------------------------------------------------------
# Optional integrations (events bus + health-check + named queries + readers)
# ---------------------------------------------------------------------------

variable "events_topic_arn" {
  description = "Optional SNS topic for CUR / crawler / health-check events. Null disables EventBridge integration + skips health-check digest publishing."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 365

  validation {
    condition     = var.log_retention_days >= 365
    error_message = "log_retention_days must be >= 365 (Checkov CKV_AWS_338)."
  }
}

variable "xray_tracing_enabled" {
  description = "Enable AWS X-Ray Active tracing on the health-check Lambda."
  type        = bool
  default     = true
}

variable "reserved_concurrent_executions" {
  description = "Reserve N concurrent executions for the health-check Lambda. Null = no reservation."
  type        = number
  default     = null
}

variable "lambda_runtime" {
  type    = string
  default = "python3.12"
}

variable "cross_account_readers" {
  description = <<-EOT
    Cross-account IAM roles for 3rd-party FinOps tools to assume and read CUR.

    Each entry creates an IAM role that:
      - Trusts the foreign account (account_id), with optional external_id condition
      - Grants read-only access to the cost-data bucket + Glue catalog + KMS key
      - Optionally grants Athena query permissions (enable_athena = true)

    Example for Cloudability:
      cross_account_readers = [{
        name          = "cloudability"
        account_id    = "165761016623"
        external_id   = var.cloudability_external_id
        enable_athena = false
      }]
  EOT
  type = list(object({
    name          = string
    account_id    = string
    external_id   = optional(string, null)
    role_name     = optional(string, null)
    enable_athena = optional(bool, false)
  }))
  default = []

  validation {
    condition     = alltrue([for r in var.cross_account_readers : can(regex("^\\d{12}$", r.account_id))])
    error_message = "cross_account_readers[*].account_id must be a 12-digit AWS account ID."
  }
}

variable "enable_health_check" {
  description = "Deploy the daily health-check Lambda (verifies CUR delivery + crawler success + Athena queryability)."
  type        = bool
  default     = true
}

variable "health_check_schedule_cron" {
  description = "EventBridge cron expression (UTC, six fields) for the health-check Lambda."
  type        = string
  default     = "0 9 * * ? *"
}

variable "cur_freshness_alarm_hours" {
  description = "Alarm if the most-recent CUR delivery is older than this. Null disables."
  type        = number
  default     = 36
}

variable "enable_named_queries" {
  description = "Register the pre-built FinOps Athena named-queries library in the workgroup."
  type        = bool
  default     = true
}

variable "extra_named_queries" {
  description = "Additional Athena named queries to register alongside the built-in library. Map of friendly name → { description, query }."
  type = map(object({
    description = string
    query       = string
  }))
  default = {}
}

data "aws_region" "current" {}

###############################################################################
# S3 bucket for cost data
###############################################################################

resource "aws_s3_bucket" "cost_data" {
  # checkov:skip=CKV_AWS_18: S3 access logging duplicates information CloudTrail S3 data events provide more thoroughly. Recommended pattern: enable CloudTrail data events on this bucket at the org level (out of scope for this module).
  # checkov:skip=CKV_AWS_144: Cross-region replication of CUR data is overkill — AWS can regenerate any month's CUR on request. CRR would double storage cost without proportional audit value.
  # checkov:skip=CKV2_AWS_62: S3 event notifications are not needed for CUR — the framework's daily health-check Lambda probes freshness on a schedule; event-driven processing isn't required.
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

resource "aws_glue_security_configuration" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0

  name = "${var.name_prefix}-cur-secconfig"

  # Checkov CKV_AWS_195 — Glue components must be associated with a security
  # configuration. CUR data is at-rest-encrypted in S3 via SSE-KMS already
  # (mode = SSE-KMS), CloudWatch crawler logs via SSE-KMS, job bookmarks
  # via CSE-KMS so the bookmark database read at crawl-time is encrypted.
  encryption_configuration {
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }
    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }
  }
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

  # Attach the security configuration created above (CKV_AWS_195).
  security_configuration = aws_glue_security_configuration.cur[0].name

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
  # checkov:skip=CKV_AWS_18: Athena query results are ephemeral (30d lifecycle); CloudTrail data events cover anything audit-relevant.
  # checkov:skip=CKV_AWS_21: Versioning IS enabled below via aws_s3_bucket_versioning.athena_results — Checkov can't trace the linked resource.
  # checkov:skip=CKV_AWS_144: Cross-region replication of ephemeral query results is wasteful — results regenerate on re-query.
  # checkov:skip=CKV_AWS_145: KMS encryption IS configured below via aws_s3_bucket_server_side_encryption_configuration.athena_results — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_6: Public access block IS configured below via aws_s3_bucket_public_access_block.athena_results — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_61: Lifecycle config IS configured below via aws_s3_bucket_lifecycle_configuration.athena_results — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_62: S3 event notifications not needed for Athena results bucket — Athena writes/reads on a synchronous query basis.
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = "${var.bucket_name}-athena-results"
  tags   = merge(var.default_tags, { Purpose = "athena-query-results" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "athena_results" {
  count  = var.enable_athena_workgroup ? 1 : 0
  bucket = aws_s3_bucket.athena_results[0].id

  versioning_configuration {
    status = "Enabled"
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
    # Noncurrent versions (introduced when versioning was enabled) — clean up
    # promptly. Query results are ephemeral by design.
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    # Checkov CKV_AWS_300 — abort orphaned multipart uploads after 7d so
    # interrupted Athena writes don't accumulate storage charges silently.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.athena_results]
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
# Cross-account reader IAM roles
#
# For each entry in var.cross_account_readers, provision a role the foreign
# account can assume (with optional external-ID condition). Grants read-only
# access to the cost-data bucket, the Glue catalog, the KMS key (to decrypt
# CUR data), and optionally Athena.
###############################################################################

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

###############################################################################
# Athena named queries — pre-built FinOps query library
#
# Registered against the framework's Athena workgroup. Each appears in the
# Athena console under "Saved queries", ready to run with one click.
#
# All queries use `local.cur2_table_name` (created by the crawler) and the
# `billing_period` partition (YYYY-MM string) which CUR 2.0 uses natively.
###############################################################################

locals {
  named_queries = (var.enable_named_queries && var.enable_athena_workgroup) ? merge({
    top-services-mtd = {
      description = "Top 20 services by unblended cost, month-to-date."
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
        LIMIT 20
      SQL
    }
    top-services-mom = {
      description = "Month-over-month % change in unblended cost, by service. Largest absolute swings first."
      query       = <<-SQL
        WITH t AS (
          SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS this_month
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period = date_format(current_date, '%Y-%m')
          GROUP BY 1
        ),
        l AS (
          SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS last_month
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period = date_format(current_date - interval '1' month, '%Y-%m')
          GROUP BY 1
        )
        SELECT
          COALESCE(t.service, l.service) AS service,
          ROUND(COALESCE(t.this_month, 0), 2) AS this_month_usd,
          ROUND(COALESCE(l.last_month, 0), 2) AS last_month_usd,
          ROUND(COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0), 2) AS delta_usd,
          ROUND(100.0 * (COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0)) / NULLIF(l.last_month, 0), 2) AS pct_change
        FROM t FULL OUTER JOIN l ON t.service = l.service
        ORDER BY ABS(COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0)) DESC
      SQL
    }
    cost-by-business-unit = {
      description = "Cost per BusinessUnit tag value, current month. 'unallocated' = untagged."
      query       = <<-SQL
        SELECT
          COALESCE(resource_tags['user_BusinessUnit'], 'unallocated') AS business_unit,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    cost-by-owner = {
      description = "Cost per Owner tag value, current month."
      query       = <<-SQL
        SELECT
          COALESCE(resource_tags['user_Owner'], 'unowned') AS owner,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    untagged-cost = {
      description = "Cost of resources missing the CostCenter tag, by service. Indicates allocation gap."
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          COUNT(DISTINCT line_item_resource_id) AS untagged_resources,
          ROUND(SUM(line_item_unblended_cost), 2) AS untagged_cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND line_item_resource_id IS NOT NULL
          AND line_item_resource_id != ''
          AND (resource_tags['user_CostCenter'] IS NULL OR resource_tags['user_CostCenter'] = '')
        GROUP BY 1
        ORDER BY 3 DESC
      SQL
    }
    ec2-by-instance-type = {
      description = "EC2 cost by instance type + region, current month."
      query       = <<-SQL
        SELECT
          product_instance_type AS instance_type,
          product_region AS region,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS hours
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonEC2'
          AND line_item_usage_type LIKE '%BoxUsage%'
        GROUP BY 1, 2
        ORDER BY 3 DESC
        LIMIT 50
      SQL
    }
    data-transfer-breakdown = {
      description = "Data transfer costs broken down by type (NAT GW, inter-region, internet, VPC peering, etc.)"
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          line_item_usage_type AS usage_type,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS gb_transferred
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND (
            line_item_usage_type LIKE '%DataTransfer%'
            OR line_item_usage_type LIKE '%NatGateway%'
            OR line_item_usage_type LIKE '%Bytes%'
          )
        GROUP BY 1, 2
        ORDER BY 3 DESC
        LIMIT 30
      SQL
    }
    daily-cost-trend = {
      description = "Daily unblended cost for the last 30 days, with 7-day moving average."
      query       = <<-SQL
        WITH daily AS (
          SELECT
            DATE(line_item_usage_start_date) AS day,
            ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period >= date_format(current_date - interval '1' month, '%Y-%m')
            AND DATE(line_item_usage_start_date) >= current_date - interval '30' day
          GROUP BY 1
        )
        SELECT
          day,
          cost_usd,
          ROUND(AVG(cost_usd) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS moving_avg_7d
        FROM daily
        ORDER BY day DESC
      SQL
    }
    top-resources-mtd = {
      description = "Top 50 individual resources by cost, current month."
      query       = <<-SQL
        SELECT
          line_item_resource_id AS resource_id,
          product_servicecode AS service,
          product_region AS region,
          resource_tags['user_Owner'] AS owner,
          resource_tags['user_BusinessUnit'] AS business_unit,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND line_item_resource_id IS NOT NULL
          AND line_item_resource_id != ''
        GROUP BY 1, 2, 3, 4, 5
        ORDER BY 6 DESC
        LIMIT 50
      SQL
    }
    s3-by-storage-class = {
      description = "S3 cost broken down by storage class (Standard, Glacier IR, Deep Archive, etc.)"
      query       = <<-SQL
        SELECT
          line_item_usage_type AS usage_type,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS gb_month
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonS3'
          AND line_item_usage_type LIKE '%TimedStorage%'
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    ri-utilization-snapshot = {
      description = "RI-covered usage vs total usage by instance family, current month."
      query       = <<-SQL
        SELECT
          product_instance_family AS family,
          ROUND(SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage' THEN line_item_usage_amount ELSE 0 END), 2) AS ri_hours,
          ROUND(SUM(line_item_usage_amount), 2) AS total_hours,
          ROUND(100.0 * SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage' THEN line_item_usage_amount ELSE 0 END) / NULLIF(SUM(line_item_usage_amount), 0), 2) AS ri_coverage_pct
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonEC2'
          AND line_item_usage_type LIKE '%BoxUsage%'
        GROUP BY 1
        ORDER BY 3 DESC
      SQL
    }
    cost-by-region = {
      description = "Total cost by AWS region, current month. Identifies multi-region sprawl."
      query       = <<-SQL
        SELECT
          COALESCE(product_region, 'global') AS region,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
  }, var.extra_named_queries) : {}
}

resource "aws_athena_named_query" "library" {
  for_each = local.named_queries

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  workgroup   = aws_athena_workgroup.finops[0].name
  database    = aws_glue_catalog_database.cur[0].name
  query       = each.value.query
}

###############################################################################
# Health-check Lambda — daily verification of the data pipeline
#
# Checks (each emits a CloudWatch metric):
#   - CurDeliveryHours        — hours since most-recent CUR file landed in S3
#   - CrawlerLastRunHours     — hours since last successful crawler run
#   - AthenaQueryability      — 1 if a probe query succeeds, 0 otherwise
#   - BucketObjectCount       — total objects in the CUR bucket
#
# Publishes a daily digest to events_topic_arn (if provided), and CloudWatch
# alarms on critical thresholds.
###############################################################################

resource "aws_sqs_queue" "health_check_dlq" {
  count = var.enable_health_check ? 1 : 0

  name                      = "${var.name_prefix}-cost-data-health-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.default_tags
}

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

data "archive_file" "health_check" {
  count       = var.enable_health_check ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/health_check.py"
  output_path = "${path.module}/lambda/health_check.zip"
}

resource "aws_cloudwatch_log_group" "health_check" {
  # checkov:skip=CKV_AWS_338: retention is driven by var.log_retention_days, validated to >= 365 at the variable level.
  count             = var.enable_health_check ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-cost-data-health"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.default_tags
}

resource "aws_lambda_function" "health_check" {
  # checkov:skip=CKV_AWS_272: Lambda code-signing requires AWS Signer; enterprise opt-in not modelled. Pin module ref for supply-chain protection.
  count = var.enable_health_check ? 1 : 0

  function_name                  = "${var.name_prefix}-cost-data-health"
  description                    = "Daily CUR + crawler + Athena health check"
  role                           = aws_iam_role.health_check[0].arn
  filename                       = data.archive_file.health_check[0].output_path
  source_code_hash               = data.archive_file.health_check[0].output_base64sha256
  handler                        = "health_check.handler"
  runtime                        = var.lambda_runtime
  timeout                        = 300
  memory_size                    = 256
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = {
      BUCKET_NAME      = aws_s3_bucket.cost_data.id
      CRAWLER_NAME     = var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : ""
      ATHENA_WORKGROUP = var.enable_athena_workgroup ? aws_athena_workgroup.finops[0].name : ""
      ATHENA_DATABASE  = var.enable_athena_workgroup ? aws_glue_catalog_database.cur[0].name : ""
      CUR_TABLE        = var.enable_athena_workgroup ? local.cur2_table_name : ""
      SNS_TOPIC_ARN    = coalesce(var.events_topic_arn, "")
      METRIC_NAMESPACE = "FinOps/CostDataExports"
    }
  }

  tracing_config {
    mode = var.xray_tracing_enabled ? "Active" : "PassThrough"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.health_check_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.health_check]
  tags       = var.default_tags
}

resource "aws_cloudwatch_event_rule" "health_check" {
  count               = var.enable_health_check ? 1 : 0
  name                = "${var.name_prefix}-cost-data-health"
  schedule_expression = "cron(${var.health_check_schedule_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "health_check" {
  count     = var.enable_health_check ? 1 : 0
  rule      = aws_cloudwatch_event_rule.health_check[0].name
  target_id = "health-check"
  arn       = aws_lambda_function.health_check[0].arn
}

resource "aws_lambda_permission" "health_check_events" {
  count         = var.enable_health_check ? 1 : 0
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_check[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check[0].arn
}

###############################################################################
# Alarms on the health-check Lambda + on the freshness metric it emits
###############################################################################

resource "aws_cloudwatch_metric_alarm" "health_check_errors" {
  count = var.enable_health_check ? 1 : 0

  alarm_name          = "${var.name_prefix}-cost-data-health-errors"
  alarm_description   = "Cost-data-exports health-check Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.health_check[0].function_name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  tags                = var.default_tags
}

resource "aws_cloudwatch_metric_alarm" "cur_freshness" {
  count = var.enable_health_check && var.cur_freshness_alarm_hours != null ? 1 : 0

  alarm_name          = "${var.name_prefix}-cur-delivery-stale"
  alarm_description   = "Most-recent CUR delivery is older than ${var.cur_freshness_alarm_hours} hours — delivery may have failed."
  namespace           = "FinOps/CostDataExports"
  metric_name         = "CurDeliveryHours"
  statistic           = "Maximum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.cur_freshness_alarm_hours
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []
  tags                = var.default_tags
}

###############################################################################
# EventBridge integration — fire to events_topic_arn on:
#   - Glue crawler state changes (Succeeded / Failed)
###############################################################################

resource "aws_cloudwatch_event_rule" "crawler_state" {
  count = var.events_topic_arn != null && var.enable_athena_workgroup ? 1 : 0

  name        = "${var.name_prefix}-crawler-state"
  description = "Forward Glue crawler state changes to the events bus"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Crawler State Change"]
    detail = {
      crawlerName = [aws_glue_crawler.cur[0].name]
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "crawler_state_to_sns" {
  count = var.events_topic_arn != null && var.enable_athena_workgroup ? 1 : 0

  rule      = aws_cloudwatch_event_rule.crawler_state[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      crawler = "$.detail.crawlerName"
      state   = "$.detail.state"
      message = "$.detail.message"
      ts      = "$.time"
    }
    input_template = <<EOF
{
  "AlertName": "FinOps CUR crawler state change",
  "severity": "info",
  "Crawler": <crawler>,
  "State": <state>,
  "Message": <message>,
  "Timestamp": <ts>
}
EOF
  }
}

###############################################################################
# CloudWatch dashboard — operational view of the cost-data pipeline
###############################################################################

resource "aws_cloudwatch_dashboard" "cost_data" {
  count = var.enable_health_check ? 1 : 0

  dashboard_name = "${var.name_prefix}-cost-data-exports"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6,
        properties = {
          title   = "CUR delivery freshness (hours since last file)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [["FinOps/CostDataExports", "CurDeliveryHours"]]
          annotations = var.cur_freshness_alarm_hours != null ? {
            horizontal = [{ value = var.cur_freshness_alarm_hours, label = "Stale threshold", color = "#FF8C00" }]
          } : {}
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6,
        properties = {
          title   = "Crawler last-success age (hours)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [["FinOps/CostDataExports", "CrawlerLastRunHours"]]
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6,
        properties = {
          title   = "Athena queryability (1 = OK)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Minimum",
          metrics = [["FinOps/CostDataExports", "AthenaQueryability"]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Cost-data bucket size (GB)"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            ["AWS/S3", "BucketSizeBytes", "StorageType", "StandardStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "GlacierIRStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "DeepArchiveStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title   = "Object count in cost-data bucket"
          view    = "timeSeries", stacked = false,
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [["AWS/S3", "NumberOfObjects", "StorageType", "AllStorageTypes", "BucketName", aws_s3_bucket.cost_data.id]]
        }
      },
      {
        type = "text", x = 0, y = 12, width = 24, height = 2,
        properties = {
          markdown = "## Cost data exports pipeline\n\n**Bucket:** `${aws_s3_bucket.cost_data.id}` — **CUR export:** `${aws_bcmdataexports_export.cur2.export[0].name}` — **Crawler:** `${var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : "(disabled)"}` — **DB.Table:** `${var.enable_athena_workgroup ? "${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}" : "(disabled)"}`"
        }
      },
    ]
  })
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
  value       = aws_bcmdataexports_export.cur2.arn
}

output "focus_export_arn" {
  description = "ARN of the FOCUS 1.0 BCM Data Export (null if disabled)."
  value       = var.enable_focus_export ? aws_bcmdataexports_export.focus[0].arn : null
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

output "cross_account_reader_role_arns" {
  description = "Map of cross-account-reader logical name → IAM role ARN. Feed these into your 3rd-party FinOps tool's account-onboarding wizard."
  value       = { for k, r in aws_iam_role.cross_account_reader : k => r.arn }
}

output "named_query_ids" {
  description = "Map of named-query friendly name → Athena named-query ID. Visible in the Athena console under 'Saved queries'."
  value       = { for k, q in aws_athena_named_query.library : k => q.id }
}

output "health_check_lambda_arn" {
  description = "ARN of the daily health-check Lambda (null if disabled)."
  value       = var.enable_health_check ? aws_lambda_function.health_check[0].arn : null
}

output "health_check_dlq_arn" {
  description = "DLQ ARN for the health-check Lambda."
  value       = var.enable_health_check ? aws_sqs_queue.health_check_dlq[0].arn : null
}

output "dashboard_name" {
  description = "Auto-provisioned CloudWatch dashboard for the cost-data-exports pipeline."
  value       = var.enable_health_check ? aws_cloudwatch_dashboard.cost_data[0].dashboard_name : null
}

output "metric_namespace" {
  description = "CloudWatch namespace under which health-check metrics are emitted."
  value       = "FinOps/CostDataExports"
}
