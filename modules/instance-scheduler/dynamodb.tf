###############################################################################
# DynamoDB — STATE + ACTION single-table design
#
# PK = "<ResourceType>#<ResourceId>"   e.g. "EC2#i-0abc1234"
# SK = "STATE"                          one current-state row per resource
#    = "ACTION#<iso-ts>-<random>"       append-only audit log row
#
# CMK-encrypted, PITR enabled, TTL-managed, prevent_destroy.
###############################################################################

resource "aws_dynamodb_table" "state" {
  name         = "${var.name_prefix}-scheduler-state"
  billing_mode = "PAY_PER_REQUEST"

  # NOTE: hash_key / range_key are deprecated in favour of key_schema in
  # newer AWS provider versions, but the replacement syntax isn't stable
  # enough across provider versions yet. Apply works fine with the
  # deprecation warning; migrate when the AWS provider stabilises.
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

  # GSI1 — date-keyed action history. Lets you query "all actions on
  # 2026-05-29" without scanning the whole table.
  #
  #   GSI1PK = "ACTION#YYYY-MM-DD"       partition per UTC date
  #   GSI1SK = "<iso-ts>-<uuid-suffix>"  chronological within the day
  #
  # STATE rows do not carry GSI1 keys, so they're transparent to the index.
  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "ActionsByDate"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
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
