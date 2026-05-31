###############################################################################
# Data sources — caller, partition, SNS topic policy document
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "AllowAccountOwners"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
    actions   = ["SNS:Publish", "SNS:Subscribe"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowAWSServicePublishers"
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "budgets.amazonaws.com",
        "costalerts.amazonaws.com",
        "events.amazonaws.com",
        "cloudwatch.amazonaws.com",
      ]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}
