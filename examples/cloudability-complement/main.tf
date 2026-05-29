# =============================================================================
# Cloudability-complement Deployment Example
#
# For organizations that already run Apptio Cloudability for FinOps analytics
# and want this Terraform framework to fill the gaps Cloudability can't fill —
# specifically the EXECUTION + ENFORCEMENT + AUDIT layers.
#
# What Cloudability owns:
#   • Multi-cloud dashboards
#   • Business Mappings (allocation as GUI config)
#   • Anomaly detection
#   • Rightsizing recommendations
#   • RI/SP coverage & utilization analytics
#   • Cross-account roll-up
#
# What this framework owns (enabled here):
#   ✅ cost-data-exports        CUR 2.0 + FOCUS — feeds Cloudability AND
#                                gives you Athena for forensic queries
#   ✅ tag-governance           Config rules + tag-drift audit
#                                (Cloudability detects, framework enforces)
#   ✅ budgets                  Budgets WITH AWS Budget Actions
#                                (Cloudability budgets are advisory only)
#   ✅ idle-resource-cleanup    Auto-cleanup with DDB audit trail
#                                (Cloudability identifies, can't act)
#   ✅ instance-scheduler       Tag-driven EC2/RDS/ASG start/stop
#   ✅ alerting (always-on)     Events bus for in-account AWS signals
#
# What's explicitly disabled — Cloudability supersedes:
#   ❌ finops-metrics            (Cloudability dashboards are better)
# =============================================================================

module "finops" {
  source = "../../"

  # === Identity ==============================================================
  namespace          = "examplecorp"
  environment        = "shared"
  stack_name         = "finops"
  aws_primary_region = "eu-central-1"

  # === Encryption (always on) ================================================
  create_kms_key               = true
  kms_key_deletion_window_days = 30

  # ---------------------------------------------------------------------------
  # DISABLED — Cloudability supersedes
  # ---------------------------------------------------------------------------

  # finops-metrics — Cloudability dashboards win on analytics. Leave OFF; the
  # DDB ACTION rows from the execution modules still feed Cloudability for the
  # parts of the story Cloudability can't see (auto-stops, idle deletions).
  finops_metrics_enabled = false

  # ---------------------------------------------------------------------------
  # ENABLED — fills Cloudability's gaps
  # ---------------------------------------------------------------------------

  # === Cost data exports =====================================================
  # KEEP — feeds Cloudability AND gives you in-account Athena.
  # Cloudability's account-onboarding wizard will ask for this bucket's ARN.
  cost_data_exports_enabled         = true
  cost_data_exports_focus_enabled   = true # for cross-cloud parity with Cloudability
  cost_data_exports_athena_enabled  = true # forensic queries ("what spiked yesterday?")
  cost_data_exports_retention_days  = 90
  cost_data_exports_expiration_days = 2557 # 7y — match Cloudability's retention

  # Cross-account reader role for Cloudability. Get the trusted account ID +
  # external ID from Cloudability's "Add AWS Account" wizard. Uncomment + set
  # values to provision the role; output cost_data_exports_cross_account_reader_role_arns
  # then feeds back into the Cloudability onboarding wizard.
  #
  # cost_data_exports_cross_account_readers = [{
  #   name          = "cloudability"
  #   account_id    = "165761016623"        # Cloudability's trusted account
  #   external_id   = var.cloudability_external_id
  #   enable_athena = false                  # set true if Cloudability runs Athena
  # }]

  # Health check + named queries are on by default. The Athena named-queries
  # library appears immediately in the Athena console under "Saved queries"
  # for forensic work Cloudability dashboards don't cover.

  # === Tag governance (THE enforcement layer Cloudability lacks) =============
  tag_governance_enabled                 = true
  tag_governance_record_global_resources = false

  tag_governance_required_tags = [
    { key = "CostCenter", allowed_values = [] },
    { key = "Environment", allowed_values = ["prod", "nonprod", "sandbox"] },
    { key = "Owner", allowed_values = [] },
    { key = "Application", allowed_values = [] },
    { key = "BusinessUnit", allowed_values = [] },
  ]

  tag_governance_taxonomy = {
    CostCenter   = { level = "mandatory", purpose = "allocation", description = "Finance CC — must match a Cloudability Business Mapping rule" }
    Environment  = { level = "mandatory", purpose = "operational", description = "Deployment environment", examples = ["prod"] }
    Owner        = { level = "mandatory", purpose = "lifecycle", description = "Email of the human owner" }
    Application  = { level = "mandatory", purpose = "allocation", description = "Logical application name" }
    BusinessUnit = { level = "mandatory", purpose = "allocation", description = "Business unit — drives Cloudability roll-up" }
  }

  tag_governance_drift_detection_enabled = true
  tag_governance_drift_watched_keys      = ["CostCenter", "BusinessUnit", "Application", "Owner"]

  # Untagged-cost report — overlaps with Cloudability tag-coverage reports.
  # Leave OFF; Cloudability is better at the dollarized gap.
  tag_governance_untagged_cost_report_enabled = false

  tag_governance_allocation_resource_groups = {
    env-prod    = { tag_key = "Environment", tag_values = ["prod"] }
    env-nonprod = { tag_key = "Environment", tag_values = ["nonprod"] }
  }

  # === Budgets WITH Budget Actions (Cloudability budgets are advisory only) ==
  budgets_currency                     = "USD"
  budgets_performance_tracking_enabled = true
  budgets_adherence_alarm_threshold    = 85

  budgets_items = {
    account_monthly = {
      scope    = "account"
      amount   = 100000
      owner    = "finops@examplecorp.com"
      approver = "cfo@examplecorp.com"
      purpose  = "Top-line account cap"
    }
    # Example: sandbox auto-freeze. When sandbox-tagged spend hits 100% of
    # this budget, AWS Budget Actions applies an IAM-deny policy to the
    # sandbox developers group, freezing further resource creation until a
    # human approves. Cloudability literally cannot do this.
    # Uncomment + adjust ARNs before enabling.
    #
    # sandbox_freeze = {
    #   scope  = "tag"
    #   amount = 5000
    #   target = { tag_key = "Environment", tag_value = "sandbox" }
    #   owner  = "platform@examplecorp.com"
    #   actions = [
    #     {
    #       threshold_pct  = 100
    #       action_type    = "APPLY_IAM_POLICY"
    #       approval_model = "AUTOMATIC"  # MANUAL = human approves first
    #       iam_policy_arn = "arn:aws:iam::123456789012:policy/DenyAllExceptRead"
    #       iam_groups     = ["sandbox-developers"]
    #     }
    #   ]
    # }
  }

  # === Idle resource cleanup (Cloudability can't act) ========================
  idle_cleanup_enabled      = true
  idle_cleanup_dry_run      = true # KEEP TRUE for the first 4 weekly cycles
  idle_cleanup_scan_regions = []   # ["us-east-1", "ap-southeast-1"] when ready

  # === Instance scheduler ====================================================
  instance_scheduler_enabled        = true
  instance_scheduler_opt_in_tag_key = "Schedule"
  instance_scheduler_schedules = {
    office-hours-cet = {
      days     = ["MON", "TUE", "WED", "THU", "FRI"]
      start    = "08:00"
      stop     = "18:00"
      timezone = "Europe/Berlin"
    }
  }

  # ---------------------------------------------------------------------------
  # Notifications
  # ---------------------------------------------------------------------------
  # These flow Slack/Teams alerts that DON'T have a Cloudability equivalent:
  #   - Tag-drift events (someone changed CostCenter on a $50k/mo RDS)
  #   - Config compliance changes
  #   - Lambda errors / DLQ depth
  #   - Budget Action firings (auto-deny applied)
  # General cost-trend alerts should stay in Cloudability.
  alerting_legacy_emails = ["finops@examplecorp.com"]

  # alerting_slack_webhook_url = var.slack_webhook_url  # set in TFE workspace
  # alerting_teams_webhook_url = var.teams_webhook_url

  # === Observability =========================================================
  log_retention_days = 365
  extra_tags = {
    Project       = "finops-platform"
    AnalyticsTool = "cloudability"
  }
}

# Outputs handy for downstream:
#   - Feed `cost_data_exports_bucket_arn` into Cloudability's account-onboarding wizard
#   - Subscribe Cloudability's webhook (or an additional email) to events_topic_arn
#     so cross-cloud alerts land alongside in-account ones
output "cost_data_exports_bucket_arn" {
  description = "S3 bucket ARN holding CUR + FOCUS. Provide this to Cloudability's AWS account-onboarding wizard."
  value       = module.finops.cost_data_exports_bucket_arn
}

output "cost_data_exports_bucket_name" {
  value = module.finops.cost_data_exports_bucket_name
}

output "events_topic_arn" {
  description = "SNS topic for in-account FinOps events. Subscribe Cloudability's webhook for cross-cloud convergence."
  value       = module.finops.events_topic_arn
}

output "framework_status" {
  description = "Single-glance status of what's deployed."
  value       = module.finops.framework_status
}

output "enabled_modules" {
  description = "Map of module -> enabled flag."
  value       = module.finops.enabled_modules
}

output "budgets_dashboard_name" {
  value = module.finops.budgets_dashboard_name
}

output "idle_cleanup_dashboard_name" {
  value = module.finops.idle_cleanup_dashboard_name
}

output "lambda_dlq_arns" {
  description = "ARNs of all Lambda DLQs. Wire into the same observability stack you use for application Lambdas."
  value       = module.finops.lambda_dlq_arns
}
