###############################################################################
# Locals — computed configuration
###############################################################################

locals {
  metric_namespace = "FinOps/KPIs"
  ssm_prefix       = "/${var.name_prefix}/kpis"

  cur_full_table = "${var.athena_database_name}.${var.cur_table_name}"

  # Build a CUR predicate that requires every allocation tag to be present.
  # CUR 2.0 exposes tags as resource_tags['user_<TagKey>'] columns.
  allocation_tag_predicate = length(var.allocation_tag_keys) > 0 ? join(" AND ", [
    for k in var.allocation_tag_keys :
    "resource_tags['user_${k}'] IS NOT NULL AND resource_tags['user_${k}'] != ''"
  ]) : "TRUE"

  # Apply substitutions to user-supplied custom KPI SQL before it's
  # serialised into the Lambda env. Keeps the SQL readable in the caller's
  # variables.
  custom_kpi_sql_substituted = {
    for k, v in var.custom_kpis :
    k => replace(replace(replace(v.sql,
      "$${cur}", local.cur_full_table),
      "$${db}", var.athena_database_name),
    "$${prefix}", var.name_prefix)
  }

  # JSON-encoded custom KPI registry passed to the Lambda. Each entry holds
  # the substituted SQL, a unit, and optional alarm config.
  custom_kpis_for_lambda = jsonencode({
    for k, v in var.custom_kpis :
    k => {
      description = v.description
      sql         = local.custom_kpi_sql_substituted[k]
      unit        = v.unit
      alarm       = v.alarm
    }
  })

  # Common Lambda env. SNS_TOPIC_ARN is coalesced to empty string so Python
  # code can use `if SNS_TOPIC_ARN:` for the standalone-mode guard.
  aggregator_env = {
    METRIC_NAMESPACE              = local.metric_namespace
    SSM_PREFIX                    = local.ssm_prefix
    ATHENA_WORKGROUP              = var.athena_workgroup_name
    ATHENA_DATABASE               = var.athena_database_name
    CUR_TABLE                     = var.cur_table_name
    CUR_FULL_TABLE                = local.cur_full_table
    ALLOCATION_TAG_KEYS           = jsonencode(var.allocation_tag_keys)
    SNS_TOPIC_ARN                 = coalesce(var.events_topic_arn, "")
    SNAPSHOT_TABLE_NAME           = aws_dynamodb_table.snapshots.name
    SNAPSHOT_TTL_DAYS             = tostring(var.snapshot_retention_days)
    BUILTIN_KPIS_ENABLED          = jsonencode(var.builtin_kpis_enabled)
    CUSTOM_KPIS_JSON              = local.custom_kpis_for_lambda
    TREND_METRICS_ENABLED         = tostring(var.trend_metrics_enabled)
    WOW_DRIFT_ALARM_THRESHOLD_PCT = var.wow_drift_alarm_threshold_pct == null ? "" : tostring(var.wow_drift_alarm_threshold_pct)
    TAG_VALUE_DASHBOARD_TAG       = coalesce(var.tag_value_dashboard_tag, "")
    TAG_VALUE_DASHBOARD_TOP_N     = tostring(var.tag_value_dashboard_top_n)
    DASHBOARD_NAME                = "${var.name_prefix}-kpis"
    NAME_PREFIX                   = var.name_prefix
  }

  # Convenience: a flat list of all KPI metric names that get emitted as
  # scalars. Used by outputs.tf to advertise the available metrics.
  builtin_scalar_kpi_metrics = compact([
    var.builtin_kpis_enabled.allocation_coverage == false ? "" : "AllocationCoveragePct",
    var.builtin_kpis_enabled.commitment_coverage == false ? "" : "CommitmentCoveragePct",
    var.builtin_kpis_enabled.commitment_utilization == false ? "" : "CommitmentUtilizationPct",
    var.builtin_kpis_enabled.anomaly_impact == false ? "" : "AnomalyImpactUsdMtd",
    var.builtin_kpis_enabled.forecast_drift == false ? "" : "ForecastAbsDriftPct",
  ])
}
