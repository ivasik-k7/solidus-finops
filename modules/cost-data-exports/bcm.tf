###############################################################################
# BCM Data Exports — CUR 2.0 + (optional) FOCUS 1.0
#
# Real CUR 2.0, not the legacy aws_cur_report_definition. Unlike the legacy
# CUR resource, aws_bcmdataexports_export does NOT auto-create a Glue table —
# that's the crawler's job (see glue.tf).
###############################################################################

resource "aws_bcmdataexports_export" "cur2" {
  export {
    name = "${var.name_prefix}-cur2"

    data_query {
      query_statement = "SELECT * FROM COST_AND_USAGE_REPORT"

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_data.id
        s3_prefix = "cur2"
        s3_region = aws_s3_bucket.cost_data.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cost_data]
}

resource "aws_bcmdataexports_export" "focus" {
  count = var.enable_focus_export ? 1 : 0

  export {
    name = "${var.name_prefix}-focus10"

    data_query {
      query_statement = "SELECT * FROM FOCUS_1_0_AWS"
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_data.id
        s3_prefix = "focus10"
        s3_region = aws_s3_bucket.cost_data.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cost_data]
}
