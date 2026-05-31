###############################################################################
# tag-governance — module entry point
#
# Capabilities implemented (FinOps Foundation Framework):
#   - Policy & Governance       required-tag enforcement (Config managed rule)
#   - Allocation                tag taxonomy as code; allocation Resource Groups
#   - Reporting & Analytics     weekly untagged-cost report Lambda; tag-health
#                               score CloudWatch metric
#   - FinOps Practice Operations  tag drift detection (allocation-relevant tag
#                                 mutations are audited via EventBridge → SNS)
#
# Design principle: NOTIFY, DO NOT MUTATE.
#
#   It is tempting to wire AWS Config remediation to "auto-tag" non-compliant
#   resources with placeholder values. We deliberately do NOT do this, because:
#     - A wrongly-applied tag can move cost to the wrong cost center, creating
#       downstream chargeback disputes.
#     - It silently masks the underlying tagging-discipline problem.
#     - It creates an unauditable shadow of "machine-applied" tags that
#       look real but are not.
#
#   The right enforcement layer is at-creation (IAM RequestTag conditions or
#   Service Control Policies) — see docs/TAG_GOVERNANCE_PATTERNS.md.
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf         provider + Terraform version requirements
#   variables.tf        all input variables
#   outputs.tf          all outputs
#   locals.tf           namespace, mandatory-tag resolution, Config rule chunking
#   data.tf             caller_identity / partition / region
#   s3.tf               Config delivery bucket (encryption, versioning, lifecycle, policy)
#   config.tf           recorder + delivery channel + required-tag rules
#   eventbridge.tf      Config compliance + tag drift + untagged-cost schedule
#   resourcegroups.tf   allocation Resource Groups
#   sqs.tf              untagged-cost report Lambda DLQ
#   iam.tf              untagged-cost report Lambda role + policy
#   lambda.tf           untagged-cost report Lambda + log group + archive
#   cloudwatch.tf       Lambda self-health + financial-gap alarms
#
# Lambda Python source: lambda/untagged_cost_report.py
# Documentation:        README.md + docs/EDGE_CASES.md + CHANGELOG.md
###############################################################################
