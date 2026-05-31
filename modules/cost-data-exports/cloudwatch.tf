###############################################################################
# CloudWatch — health-check Lambda alarms + CUR freshness alarm + dashboard
###############################################################################

# ---------------------------------------------------------------------------
# Lambda self-health
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "health_check_errors" {
  count = var.enable_health_check ? 1 : 0

  alarm_name          = "${var.name_prefix}-cost-data-health-errors"
  alarm_description   = "Cost-data-exports health-check Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.health_check[0].function_name }
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  tags                = var.default_tags
}

# ---------------------------------------------------------------------------
# CUR freshness — fires if no CUR file has landed within the threshold
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cur_freshness" {
  count = var.enable_health_check && var.cur_freshness_alarm_hours != null ? 1 : 0

  alarm_name          = "${var.name_prefix}-cur-delivery-stale"
  alarm_description   = "Most-recent CUR delivery is older than ${var.cur_freshness_alarm_hours} hours — delivery may have failed."
  namespace           = local.metric_namespace
  metric_name         = "CurDeliveryHours"
  statistic           = "Maximum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.cur_freshness_alarm_hours
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.events_topic_arn != null ? [var.events_topic_arn] : []
  ok_actions          = var.events_topic_arn != null ? [var.events_topic_arn] : []
  tags                = var.default_tags
}

# ---------------------------------------------------------------------------
# Operational dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "cost_data" {
  count = var.enable_health_check ? 1 : 0

  dashboard_name = "${var.name_prefix}-cost-data-exports"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6,
        properties = {
          title   = "CUR delivery freshness (hours since last file)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [[local.metric_namespace, "CurDeliveryHours"]]
          annotations = var.cur_freshness_alarm_hours != null ? {
            horizontal = [{ value = var.cur_freshness_alarm_hours, label = "Stale threshold", color = "#FF8C00" }]
          } : {}
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6,
        properties = {
          title   = "Crawler last-success age (hours)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [[local.metric_namespace, "CrawlerLastRunHours"]]
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6,
        properties = {
          title   = "Athena queryability (1 = OK)"
          view    = "singleValue",
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Minimum",
          metrics = [[local.metric_namespace, "AthenaQueryability"]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Cost-data bucket size (GB)"
          view   = "timeSeries", stacked = false,
          region = data.aws_region.current.region,
          period = 86400, stat = "Maximum",
          metrics = [
            ["AWS/S3", "BucketSizeBytes", "StorageType", "StandardStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "GlacierIRStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "DeepArchiveStorage", "BucketName", aws_s3_bucket.cost_data.id, { stat = "Maximum" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title   = "Object count in cost-data bucket"
          view    = "timeSeries", stacked = false,
          region  = data.aws_region.current.region,
          period  = 86400, stat = "Maximum",
          metrics = [["AWS/S3", "NumberOfObjects", "StorageType", "AllStorageTypes", "BucketName", aws_s3_bucket.cost_data.id]]
        }
      },
      {
        type = "text", x = 0, y = 12, width = 24, height = 2,
        properties = {
          markdown = "## Cost data exports pipeline\n\n**Bucket:** `${aws_s3_bucket.cost_data.id}` — **CUR export:** `${aws_bcmdataexports_export.cur2.export[0].name}` — **Crawler:** `${var.enable_athena_workgroup ? aws_glue_crawler.cur[0].name : "(disabled)"}` — **DB.Table:** `${var.enable_athena_workgroup ? "${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}" : "(disabled)"}`"
        }
      },
    ]
  })
}
