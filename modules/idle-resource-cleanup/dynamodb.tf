###############################################################################
# DynamoDB — findings state + action audit log
#
# Single-table design:
#   PK = "<ResourceType>#<ResourceId>"   e.g. "EBS#vol-0abc1234"
#   SK = "STATE" | "ACTION#<iso-ts>"
#
# STATE rows carry the current lifecycle state (new / aging / snoozed /
# excepted / approved / deleted) with TTL so stale findings auto-expire.
#
# ACTION rows are append-only and form the audit trail — every mutation
# (snapshot, delete, release) lands here with the estimated $ saved and
# the actor identifier.
#
# GSI `ByStatus` supports "show me everything snoozed / excepted / approved"
# without a table scan.
###############################################################################

resource "aws_dynamodb_table" "findings" {
  name         = "${var.name_prefix}-idle-findings"
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
  attribute {
    name = "Status"
    type = "S"
  }

  global_secondary_index {
    name            = "ByStatus"
    hash_key        = "Status"
    range_key       = "PK"
    projection_type = "ALL"
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
