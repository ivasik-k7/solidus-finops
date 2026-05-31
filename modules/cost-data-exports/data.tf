###############################################################################
# Data sources — region + S3 bucket policy document
###############################################################################

data "aws_region" "current" {}

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
