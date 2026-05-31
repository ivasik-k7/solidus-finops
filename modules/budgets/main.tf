###############################################################################
# budgets — module entry point
#
# What this module delivers beyond a stock AWS Budgets wrapper:
#
#   1. Polymorphic budget schema — account / service / tag / cost_category
#   2. Per-budget thresholds, time_unit (MONTHLY/QUARTERLY/ANNUALLY),
#      currency, notification recipients, governance metadata
#   3. AWS Budget Actions — IAM/SCP/SSM auto-enforcement on breach
#   4. Daily performance Lambda → CloudWatch metrics + SNS digest:
#         - VariancePct (actual vs limit) per budget
#         - BurnRateDaysToBreach forecast per budget
#         - BudgetAdherenceScore — % of all budgets currently within target
#         - Anomaly correlation: was this breach driven by a known anomaly?
#   5. DynamoDB-backed state + trend table (STATE + SNAPSHOT#<date> rows)
#   6. Auto-provisioned CloudWatch dashboard for the FinOps lead
#   7. CloudWatch alarms on adherence score + per-budget burn rate
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf       provider + Terraform version requirements
#   variables.tf      all input variables (incl. polymorphic budgets schema)
#   outputs.tf        all outputs
#   locals.tf         period anchors + flattened action map
#   data.tf           caller_identity / partition / region
#   dynamodb.tf       state + 90-day trend + audit-log table
#   budgets.tf        aws_budgets_budget.this + aws_budgets_budget_action.this
#   iam.tf            budget_actions role + performance Lambda role
#   sqs.tf            performance Lambda DLQ
#   lambda.tf         performance Lambda + log group + archive
#   eventbridge.tf    daily performance schedule
#   cloudwatch.tf     Lambda self-health + adherence + burn-rate alarms + dashboard
#
# Lambda Python source: lambda/budget_performance.py
# Documentation:        README.md + docs/EDGE_CASES.md + CHANGELOG.md
###############################################################################
