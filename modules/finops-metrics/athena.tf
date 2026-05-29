###############################################################################
# Athena named queries
#
# Two layers:
#   1. Built-in queries — gated by var.builtin_kpis_enabled.<kpi>. These
#      appear in the Athena console under "Saved queries" for ad-hoc BI use.
#   2. Custom queries — one per entry in var.custom_kpis. Same console
#      visibility; also executed by the aggregator Lambda.
###############################################################################

# ---------------------------------------------------------------------------
# Built-in queries (BI-visible)
# ---------------------------------------------------------------------------

resource "aws_athena_named_query" "allocation_coverage" {
  count = var.builtin_kpis_enabled.allocation_coverage ? 1 : 0

  name        = "${var.name_prefix}-kpi-allocation-coverage"
  description = "FinOps KPI: % of unblended cost carrying all allocation tags, current month."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      ROUND(100.0 * SUM(CASE WHEN ${local.allocation_tag_predicate} THEN line_item_unblended_cost ELSE 0 END)
                  / NULLIF(SUM(line_item_unblended_cost), 0), 2) AS allocation_coverage_pct,
      SUM(line_item_unblended_cost) AS total_cost_usd,
      SUM(CASE WHEN ${local.allocation_tag_predicate} THEN line_item_unblended_cost ELSE 0 END) AS allocated_cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
  SQL
}

resource "aws_athena_named_query" "spend_by_service" {
  count = var.builtin_kpis_enabled.spend_by_service ? 1 : 0

  name        = "${var.name_prefix}-kpi-spend-by-service"
  description = "FinOps KPI: unblended cost by AWS service, current month — sorted descending."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      product_servicecode AS service,
      SUM(line_item_unblended_cost) AS cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
    GROUP BY product_servicecode
    ORDER BY cost_usd DESC
  SQL
}

resource "aws_athena_named_query" "unit_cost_by_business_unit" {
  count = var.builtin_kpis_enabled.allocation_coverage ? 1 : 0

  name        = "${var.name_prefix}-kpi-unit-cost-by-business-unit"
  description = "FinOps KPI: cost per BusinessUnit tag value, current month."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    SELECT
      COALESCE(resource_tags['user_BusinessUnit'], 'unallocated') AS business_unit,
      SUM(line_item_unblended_cost) AS cost_usd
    FROM ${local.cur_full_table}
    WHERE billing_period = date_format(current_date, '%Y-%m')
    GROUP BY COALESCE(resource_tags['user_BusinessUnit'], 'unallocated')
    ORDER BY cost_usd DESC
  SQL
}

resource "aws_athena_named_query" "month_over_month_growth" {
  name        = "${var.name_prefix}-kpi-month-over-month-growth"
  description = "FinOps KPI: month-over-month % change in unblended cost, by service."
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = <<-SQL
    WITH this_month AS (
      SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost
      FROM ${local.cur_full_table}
      WHERE billing_period = date_format(current_date, '%Y-%m')
      GROUP BY product_servicecode
    ),
    last_month AS (
      SELECT product_servicecode AS service, SUM(line_item_unblended_cost) AS cost
      FROM ${local.cur_full_table}
      WHERE billing_period = date_format(current_date - interval '1' month, '%Y-%m')
      GROUP BY product_servicecode
    )
    SELECT
      COALESCE(t.service, l.service) AS service,
      COALESCE(t.cost, 0) AS this_month_cost,
      COALESCE(l.cost, 0) AS last_month_cost,
      ROUND(100.0 * (COALESCE(t.cost, 0) - COALESCE(l.cost, 0)) / NULLIF(l.cost, 0), 2) AS pct_change
    FROM this_month t
    FULL OUTER JOIN last_month l ON t.service = l.service
    ORDER BY ABS(COALESCE(t.cost, 0) - COALESCE(l.cost, 0)) DESC
  SQL
}

# ---------------------------------------------------------------------------
# User-defined custom KPIs — Terraform-registered, executed by the Lambda
# ---------------------------------------------------------------------------

resource "aws_athena_named_query" "custom" {
  for_each = var.custom_kpis

  name        = "${var.name_prefix}-kpi-custom-${each.key}"
  description = coalesce(each.value.description, "Custom FinOps KPI: ${each.key}")
  workgroup   = var.athena_workgroup_name
  database    = var.athena_database_name

  query = local.custom_kpi_sql_substituted[each.key]
}
