###############################################################################
# Computed locals
#
# Centralizes naming, tagging, and frequently-used identifiers.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Naming convention: <namespace>-<environment>-<stack_name>-<purpose>
  # Keep this consistent across modules.
  name_prefix = "${var.namespace}-${var.environment}-${var.stack_name}"

  # Default tags applied to EVERY resource via provider default_tags.
  # The framework also flows these to module-level resources for safety
  # (some resources don't inherit default_tags reliably, e.g. some
  # billing resources, autoscaling groups).
  default_tags = merge(
    {
      ManagedBy          = "terraform"
      Module             = "finops-framework"
      Owner              = "finops-team"
      CostCenter         = "finops-shared"
      Environment        = var.environment
      Application        = "finops-framework"
      BusinessUnit       = "technology-shared"
      DataClassification = "internal"
    },
    var.extra_tags,
  )

  # Resolved KMS key — either created by the framework or supplied by the caller.
  kms_key_arn = var.create_kms_key ? aws_kms_key.finops[0].arn : var.existing_kms_key_arn
  kms_key_id  = var.create_kms_key ? aws_kms_key.finops[0].key_id : null

  # Resolved cost-data bucket name. Defaults to <name_prefix>-cost-data-<account_id>
  # to avoid collisions across accounts.
  cost_data_bucket_name = coalesce(
    var.cost_data_bucket_name,
    "${local.name_prefix}-cost-data-${local.account_id}"
  )

  # Single events bus that all modules publish to (alerts, reports, governance).
  events_topic_arn = module.alerting.events_topic_arn
}
