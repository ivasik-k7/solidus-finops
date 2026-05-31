###############################################################################
# idle-resource-cleanup — module entry point
#
# Detects (and optionally cleans) idle resources across multiple AWS services.
# Every resource type:
#   - Has its own Lambda + IAM role + DLQ + Errors alarm + DLQ-depth alarm
#   - Honors var.dry_run (default true) and the exception tag
#   - Emits CloudWatch metrics under namespace FinOps/IdleResources, dimension
#     ResourceType=<type>: MonthlyWasteUsd, FoundCount, ActionsTakenCount
#   - Publishes a structured digest to the events SNS topic
#   - Respects a per-Lambda cost ceiling (USD/run) to bound blast radius
#
# Resource coverage (each individually toggleable):
#   - EBS volumes      unattached, two-phase snapshot-then-delete with grace
#   - Elastic IPs      unassociated
#   - EBS snapshots    orphaned (not AMI-backed)
#   - NAT Gateways     idle by age + CloudWatch BytesOutToDestination
#   - ENIs             leaked / unattached
#   - Load Balancers   ALB/NLB with no healthy targets + low request count
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf       provider + Terraform version requirements
#   variables.tf      all input variables (incl. per-resource-type toggles + thresholds + schedules)
#   outputs.tf        all outputs
#   locals.tf         resource-type catalog + per-type IAM statement bundles + common env vars
#   data.tf           partition / region data sources
#   dynamodb.tf       findings table (STATE + ACTION single-table, GSI ByStatus)
#   sqs.tf            per-Lambda DLQs (for_each over enabled types)
#   iam.tf            per-Lambda least-privilege role + policy
#   lambda.tf         six cleanup Lambdas + log groups + multi-source archive
#   eventbridge.tf    per-Lambda schedule rule + target + permission
#   cloudwatch.tf     per-Lambda alarms + aggregate-waste metric-math alarm + dashboard
#
# Lambda Python sources (six entrypoints + one shared helper):
#   lambda/_shared/idle_state.py
#   lambda/ebs/ebs_cleanup.py
#   lambda/eip/eip_cleanup.py
#   lambda/snapshot/snapshot_cleanup.py
#   lambda/nat/nat_cleanup.py
#   lambda/eni/eni_cleanup.py
#   lambda/lb/lb_cleanup.py
#
# Documentation: README.md + docs/EDGE_CASES.md + CHANGELOG.md
###############################################################################
