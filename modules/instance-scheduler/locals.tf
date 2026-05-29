###############################################################################
# Locals — computed configuration
###############################################################################

locals {
  metric_namespace = "FinOps/InstanceScheduler"

  # Default to the home region if no scan_regions were passed. Empty list
  # would silently scan nothing.
  effective_regions = length(var.scan_regions) > 0 ? var.scan_regions : [data.aws_region.current.region]

  # Convenience: how many schedules are configured. If 0, the module emits an
  # alarm-friendly output (`schedules_configured = 0`) so operators can build
  # an external alert. The module DOES NOT fail — empty schedules is a valid
  # state (e.g. provisioning the infrastructure ahead of defining schedules).
  schedules_count = length(var.schedules)

  # Common env vars shared by both Lambdas. SNS_TOPIC_ARN is coalesced to an
  # empty string so Lambda code can use `if SNS_TOPIC_ARN:` as a check.
  scheduler_env = {
    OPT_IN_TAG_KEY         = var.opt_in_tag_key
    EXCEPTION_TAG_KEY      = var.exception_tag_key
    OVERRIDE_UNTIL_TAG_KEY = var.override_until_tag_key
    SCHEDULES_JSON         = jsonencode(var.schedules)
    SNS_TOPIC_ARN          = coalesce(var.events_topic_arn, "")
    METRIC_NAMESPACE       = local.metric_namespace
    SCAN_REGIONS           = jsonencode(local.effective_regions)
    STATE_TABLE_NAME       = aws_dynamodb_table.state.name
    STATE_TTL_DAYS         = tostring(var.state_ttl_days)
    ACTION_TTL_DAYS        = tostring(var.action_ttl_days)
    MAX_ACTIONS_PER_TICK   = tostring(var.max_actions_per_tick)
    ENABLE_EC2             = tostring(var.enable_ec2)
    ENABLE_RDS_INSTANCES   = tostring(var.enable_rds_instances)
    ENABLE_RDS_CLUSTERS    = tostring(var.enable_rds_clusters)
    ENABLE_ASG             = tostring(var.enable_asg)
    ENABLE_SPOT_MANAGEMENT = tostring(var.enable_spot_management)
    DRY_RUN                = tostring(var.dry_run)
  }

  discovery_env = {
    OPT_IN_TAG_KEY    = var.opt_in_tag_key
    EXCEPTION_TAG_KEY = var.exception_tag_key
    SNS_TOPIC_ARN     = coalesce(var.events_topic_arn, "")
    METRIC_NAMESPACE  = local.metric_namespace
    SCAN_REGIONS      = jsonencode(local.effective_regions)
    CPU_THRESHOLD_PCT = tostring(var.discovery_cpu_threshold_pct)
    LOOKBACK_DAYS     = tostring(var.discovery_lookback_days)
  }
}
