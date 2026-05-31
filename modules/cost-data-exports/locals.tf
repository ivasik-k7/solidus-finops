###############################################################################
# Locals — Glue table naming + Athena named-queries library
###############################################################################

locals {
  metric_namespace = "FinOps/CostDataExports"

  # Deterministic Glue table name produced by the crawler.
  cur2_table_prefix = "${replace(var.name_prefix, "-", "_")}_"
  cur2_table_name   = "${local.cur2_table_prefix}data"

  # ---------------------------------------------------------------------------
  # Pre-built FinOps Athena named-queries library
  #
  # Registered against the workgroup when var.enable_named_queries is true.
  # Each appears in the Athena console under "Saved queries", ready to run.
  # Callers can extend via var.extra_named_queries (merged below).
  # ---------------------------------------------------------------------------

  named_queries = (var.enable_named_queries && var.enable_athena_workgroup) ? merge({
    top-services-mtd = {
      description = "Top 20 services by unblended cost, month-to-date."
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
        LIMIT 20
      SQL
    }
    top-services-mom = {
      description = "Month-over-month % change in unblended cost, by service. Largest absolute swings first."
      query       = <<-SQL
        WITH t AS (
          SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS this_month
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period = date_format(current_date, '%Y-%m')
          GROUP BY 1
        ),
        l AS (
          SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS last_month
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period = date_format(current_date - interval '1' month, '%Y-%m')
          GROUP BY 1
        )
        SELECT
          COALESCE(t.service, l.service) AS service,
          ROUND(COALESCE(t.this_month, 0), 2) AS this_month_usd,
          ROUND(COALESCE(l.last_month, 0), 2) AS last_month_usd,
          ROUND(COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0), 2) AS delta_usd,
          ROUND(100.0 * (COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0)) / NULLIF(l.last_month, 0), 2) AS pct_change
        FROM t FULL OUTER JOIN l ON t.service = l.service
        ORDER BY ABS(COALESCE(t.this_month, 0) - COALESCE(l.last_month, 0)) DESC
      SQL
    }
    cost-by-business-unit = {
      description = "Cost per BusinessUnit tag value, current month. 'unallocated' = untagged."
      query       = <<-SQL
        SELECT
          COALESCE(resource_tags['user_BusinessUnit'], 'unallocated') AS business_unit,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    cost-by-owner = {
      description = "Cost per Owner tag value, current month."
      query       = <<-SQL
        SELECT
          COALESCE(resource_tags['user_Owner'], 'unowned') AS owner,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    untagged-cost = {
      description = "Cost of resources missing the CostCenter tag, by service. Indicates allocation gap."
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          COUNT(DISTINCT line_item_resource_id) AS untagged_resources,
          ROUND(SUM(line_item_unblended_cost), 2) AS untagged_cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND line_item_resource_id IS NOT NULL
          AND line_item_resource_id != ''
          AND (resource_tags['user_CostCenter'] IS NULL OR resource_tags['user_CostCenter'] = '')
        GROUP BY 1
        ORDER BY 3 DESC
      SQL
    }
    ec2-by-instance-type = {
      description = "EC2 cost by instance type + region, current month."
      query       = <<-SQL
        SELECT
          product_instance_type AS instance_type,
          product_region AS region,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS hours
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonEC2'
          AND line_item_usage_type LIKE '%BoxUsage%'
        GROUP BY 1, 2
        ORDER BY 3 DESC
        LIMIT 50
      SQL
    }
    data-transfer-breakdown = {
      description = "Data transfer costs broken down by type (NAT GW, inter-region, internet, VPC peering, etc.)"
      query       = <<-SQL
        SELECT
          product_servicecode AS service,
          line_item_usage_type AS usage_type,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS gb_transferred
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND (
            line_item_usage_type LIKE '%DataTransfer%'
            OR line_item_usage_type LIKE '%NatGateway%'
            OR line_item_usage_type LIKE '%Bytes%'
          )
        GROUP BY 1, 2
        ORDER BY 3 DESC
        LIMIT 30
      SQL
    }
    daily-cost-trend = {
      description = "Daily unblended cost for the last 30 days, with 7-day moving average."
      query       = <<-SQL
        WITH daily AS (
          SELECT
            DATE(line_item_usage_start_date) AS day,
            ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
          FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
          WHERE billing_period >= date_format(current_date - interval '1' month, '%Y-%m')
            AND DATE(line_item_usage_start_date) >= current_date - interval '30' day
          GROUP BY 1
        )
        SELECT
          day,
          cost_usd,
          ROUND(AVG(cost_usd) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS moving_avg_7d
        FROM daily
        ORDER BY day DESC
      SQL
    }
    top-resources-mtd = {
      description = "Top 50 individual resources by cost, current month."
      query       = <<-SQL
        SELECT
          line_item_resource_id AS resource_id,
          product_servicecode AS service,
          product_region AS region,
          resource_tags['user_Owner'] AS owner,
          resource_tags['user_BusinessUnit'] AS business_unit,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND line_item_resource_id IS NOT NULL
          AND line_item_resource_id != ''
        GROUP BY 1, 2, 3, 4, 5
        ORDER BY 6 DESC
        LIMIT 50
      SQL
    }
    s3-by-storage-class = {
      description = "S3 cost broken down by storage class (Standard, Glacier IR, Deep Archive, etc.)"
      query       = <<-SQL
        SELECT
          line_item_usage_type AS usage_type,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd,
          ROUND(SUM(line_item_usage_amount), 2) AS gb_month
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonS3'
          AND line_item_usage_type LIKE '%TimedStorage%'
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
    ri-utilization-snapshot = {
      description = "RI-covered usage vs total usage by instance family, current month."
      query       = <<-SQL
        SELECT
          product_instance_family AS family,
          ROUND(SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage' THEN line_item_usage_amount ELSE 0 END), 2) AS ri_hours,
          ROUND(SUM(line_item_usage_amount), 2) AS total_hours,
          ROUND(100.0 * SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage' THEN line_item_usage_amount ELSE 0 END) / NULLIF(SUM(line_item_usage_amount), 0), 2) AS ri_coverage_pct
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
          AND product_servicecode = 'AmazonEC2'
          AND line_item_usage_type LIKE '%BoxUsage%'
        GROUP BY 1
        ORDER BY 3 DESC
      SQL
    }
    cost-by-region = {
      description = "Total cost by AWS region, current month. Identifies multi-region sprawl."
      query       = <<-SQL
        SELECT
          COALESCE(product_region, 'global') AS region,
          ROUND(SUM(line_item_unblended_cost), 2) AS cost_usd
        FROM ${aws_glue_catalog_database.cur[0].name}.${local.cur2_table_name}
        WHERE billing_period = date_format(current_date, '%Y-%m')
        GROUP BY 1
        ORDER BY 2 DESC
      SQL
    }
  }, var.extra_named_queries) : {}
}
