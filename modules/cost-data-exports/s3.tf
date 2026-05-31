###############################################################################
# S3 — two buckets
#
#   1. cost_data       holds CUR + FOCUS data. prevent_destroy = true.
#                      Lifecycle: GLACIER_IR after retention window, expire at
#                      total retention. Noncurrent versions → Deep Archive
#                      after 7d, expire at 90d.
#
#   2. athena_results  holds Athena query outputs. 30-day TTL on objects.
#                      Created only when var.enable_athena_workgroup = true.
###############################################################################

# ---------------------------------------------------------------------------
# Cost data bucket — CUR + FOCUS
# ---------------------------------------------------------------------------

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

resource "aws_s3_bucket_policy" "cost_data" {
  bucket = aws_s3_bucket.cost_data.id
  policy = data.aws_iam_policy_document.cost_data.json
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

# ---------------------------------------------------------------------------
# Athena results bucket — ephemeral query outputs (30d TTL)
# ---------------------------------------------------------------------------

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
