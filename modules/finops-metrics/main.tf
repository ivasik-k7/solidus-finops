###############################################################################
# finops-metrics — module entry point
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf      provider + Terraform version requirements
#   variables.tf     all input variables
#   outputs.tf       all outputs
#   locals.tf        computed locals (env vars, namespace, CUR predicate)
#   data.tf          data sources (caller_identity, partition, region)
#   iam.tf           aggregator role + policy
#   dynamodb.tf      kpi-snapshots table (daily history, drives trend metrics)
#   sqs.tf           DLQ
#   athena.tf        built-in + user-defined named queries
#   lambda.tf        aggregator Lambda + log group + archive_file
#   eventbridge.tf   daily trigger
#   cloudwatch.tf    Lambda-self + KPI-threshold alarms + dashboard skeleton
#
# Lambda Python source: lambda/kpi_aggregator.py
# Documentation:        README.md + docs/EDGE_CASES.md
###############################################################################
