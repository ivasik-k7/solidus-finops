###############################################################################
# instance-scheduler — module entry point
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf      provider + Terraform version requirements
#   variables.tf     all input variables
#   outputs.tf       all outputs
#   locals.tf        computed locals (env vars, region list, namespaces)
#   data.tf          data sources (caller_identity, partition, region)
#   iam.tf           IAM roles + policies (scheduler + discovery)
#   dynamodb.tf      STATE + ACTION single-table
#   sqs.tf           per-Lambda DLQs
#   lambda.tf        Lambdas, log groups, archive_files
#   eventbridge.tf   schedule triggers + targets + permissions
#   cloudwatch.tf    alarms + auto-provisioned dashboard
#
# Lambda Python source: lambda/scheduler.py + lambda/discovery.py
# Documentation:        README.md + docs/EDGE_CASES.md
###############################################################################
