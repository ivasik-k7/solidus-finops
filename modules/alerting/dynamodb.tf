###############################################################################
# DynamoDB — single table for audit log + dedup cache
#
# PK = "DEDUP#<fingerprint-sha>"  →  short-TTL row, suppresses repeat fires
# PK = "AUDIT#<iso-ts>-<random>"  →  permanent audit row per dispatched event
#
# Both record types share a TTL column (ExpireAt); audit rows get the
# configured retention, dedup rows get the configured window.
###############################################################################

resource "aws_dynamodb_table" "events" {
  count = (var.audit_log.enabled != false || var.deduplication.enabled != false) ? 1 : 0

  name         = "${var.name_prefix}-alerting-events"
  billing_mode = "PAY_PER_REQUEST"
  # NOTE: hash_key/range_key are deprecated in favor of key_schema in newer
  # AWS provider versions, but the replacement syntax is still in flux.
  # Apply works fine with the deprecation warning. Migrate when stable.
  hash_key = "PK"

  attribute {
    name = "PK"
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
