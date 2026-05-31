###############################################################################
# Glue — catalog database + security configuration + CUR crawler
#
# Operational note: the crawler runs daily at 06:00 UTC. On first apply, the
# first CUR delivery happens within ~24h and the first crawler run picks it
# up. Athena queries are non-functional until both have completed (~24-48h
# after `terraform apply`).
###############################################################################

# ---------------------------------------------------------------------------
# Catalog database
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0
  name  = replace("${var.name_prefix}_cur", "-", "_")

  description = "Glue database for FinOps CUR 2.0 and FOCUS tables."
}

# ---------------------------------------------------------------------------
# Security configuration — Checkov CKV_AWS_195
#
# CUR data is at-rest-encrypted in S3 via SSE-KMS already (mode = SSE-KMS);
# CloudWatch crawler logs via SSE-KMS; job bookmarks via CSE-KMS so the
# bookmark database read at crawl-time is encrypted.
# ---------------------------------------------------------------------------

resource "aws_glue_security_configuration" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0

  name = "${var.name_prefix}-cur-secconfig"

  encryption_configuration {
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }
    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }
  }
}

# ---------------------------------------------------------------------------
# CUR crawler — discovers schema + partitions
# ---------------------------------------------------------------------------

resource "aws_glue_crawler" "cur" {
  count = var.enable_athena_workgroup ? 1 : 0

  name          = "${var.name_prefix}-cur-crawler"
  description   = "Discovers CUR 2.0 schema + partitions for Athena."
  database_name = aws_glue_catalog_database.cur[0].name
  role          = aws_iam_role.cur_crawler[0].arn

  # Deterministic table name: <namespace_env_stack>_data
  table_prefix = local.cur2_table_prefix

  # Daily at 06:00 UTC — CUR refreshes a few times a day; once is enough to
  # pick up the new BILLING_PERIOD partition when a month rolls over.
  schedule = "cron(0 6 * * ? *)"

  # Attach the security configuration created above (CKV_AWS_195).
  security_configuration = aws_glue_security_configuration.cur[0].name

  s3_target {
    # BCM Data Exports writes to <prefix>/<export>/<export>/data/BILLING_PERIOD=YYYY-MM/
    path = "s3://${aws_s3_bucket.cost_data.id}/cur2/${aws_bcmdataexports_export.cur2.export[0].name}/${aws_bcmdataexports_export.cur2.export[0].name}/data/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.default_tags

  depends_on = [aws_bcmdataexports_export.cur2]
}
