###############################################################################
# DynamoDB — KPI snapshot history
#
# PK = "KPI#<MetricName>"   e.g. "KPI#AllocationCoveragePct"
# SK = "<YYYY-MM-DD>"        one row per day per KPI
#
# Holds the value, unit, and any dimensions. The aggregator Lambda reads
# the last 30 days back to compute moving averages + week-over-week drift.
# CMK-encrypted, PITR enabled, TTL on ExpireAt.
#
# Snapshots are derived data — recomputable by re-running the aggregator
# for the last N days. No prevent_destroy here.
###############################################################################

resource "aws_dynamodb_table" "snapshots" {
  name         = "${var.name_prefix}-kpi-snapshots"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

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
}
