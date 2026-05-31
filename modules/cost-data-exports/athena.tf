###############################################################################
# Athena — workgroup + pre-built named-queries library
###############################################################################

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

# ---------------------------------------------------------------------------
# Named queries library — built-in + user-supplied extras
#
# Defined in locals.tf as `local.named_queries`. Each becomes a resource
# that shows up in the Athena console "Saved queries" panel.
# ---------------------------------------------------------------------------

resource "aws_athena_named_query" "library" {
  for_each = local.named_queries

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  workgroup   = aws_athena_workgroup.finops[0].name
  database    = aws_glue_catalog_database.cur[0].name
  query       = each.value.query
}
