###############################################################################
# DynamoDB — per-budget state + 90-day trend + audit log
#
# PK = "BUDGET#<budget-name>"
# SK = "STATE"                  current state row, overwritten daily
#    = "SNAPSHOT#<iso-date>"    one row per day, drives trend math + dashboard
#    = "ACTION#<iso-ts>"        append-only audit row for Budget Action firings
#
# CMK-encrypted, PITR enabled, TTL on ExpireAt, prevent_destroy on.
###############################################################################

resource "aws_dynamodb_table" "state" {
  count = var.enable_performance_tracking ? 1 : 0

  name         = "${var.name_prefix}-budgets-state"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "ExpireAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = var.default_tags

  lifecycle {
    prevent_destroy = true
  }
}
