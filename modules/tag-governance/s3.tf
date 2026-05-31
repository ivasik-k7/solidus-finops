###############################################################################
# S3 — AWS Config delivery bucket
#
# Append-only history bucket. Lifecycle simply cleans up noncurrent versions
# + aborts orphaned multipart uploads. Current versions retained indefinitely
# — they're the audit trail.
###############################################################################

resource "aws_s3_bucket" "config" {
  # checkov:skip=CKV_AWS_18: Config delivery bucket holds AWS Config history; CloudTrail data events provide the audit-grade access log. S3 access logging would create a chicken-and-egg problem (the logs bucket itself needs logging).
  # checkov:skip=CKV_AWS_21: Versioning IS enabled below via aws_s3_bucket_versioning.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV_AWS_144: Cross-region replication of Config history would double cost without proportional audit value — AWS Config can replay history from CloudTrail if the bucket is lost.
  # checkov:skip=CKV_AWS_145: KMS encryption IS configured below via aws_s3_bucket_server_side_encryption_configuration.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_6: Public access block IS configured below via aws_s3_bucket_public_access_block.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_61: Lifecycle config IS configured below via aws_s3_bucket_lifecycle_configuration.config — Checkov can't trace the linked resource.
  # checkov:skip=CKV2_AWS_62: S3 event notifications not needed — AWS Config delivers on its own schedule; no event-driven downstream processing.
  count  = var.enable_config_recorder ? 1 : 0
  bucket = "${var.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
  tags   = merge(var.default_tags, { Purpose = "aws-config-delivery" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_config_recorder ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  rule {
    id     = "noncurrent-cleanup"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}
