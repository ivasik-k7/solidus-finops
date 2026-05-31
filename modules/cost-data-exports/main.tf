###############################################################################
# cost-data-exports — module entry point
#
# Provisions the cost-data pipeline:
#   - S3 bucket (KMS-encrypted, versioned, lifecycle-managed) for CUR/FOCUS data
#   - CUR 2.0 export via aws_bcmdataexports_export
#   - FOCUS 1.0 export via aws_bcmdataexports_export (optional)
#   - Glue catalog database + crawler that discovers the CUR 2.0 schema and
#     partitions
#   - Athena workgroup + pre-built named-queries library (optional)
#   - Cross-account reader IAM roles for 3rd-party FinOps tools
#   - Daily health-check Lambda (CUR freshness + crawler success + Athena probe)
#   - TLS-only S3 bucket policy
#
# Both exports use BCM Data Exports (no legacy CUR v1, no us-east-1 alias).
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf       provider + Terraform version requirements
#   variables.tf      all input variables
#   outputs.tf        all outputs
#   locals.tf         Glue table naming + Athena named-queries library
#   data.tf           region + S3 bucket policy document
#   s3.tf             cost-data + athena-results buckets (versioning, KMS, lifecycle, PAB, policy)
#   bcm.tf            CUR 2.0 + FOCUS 1.0 BCM Data Exports
#   glue.tf           catalog database + security configuration + CUR crawler
#   athena.tf         workgroup + named-queries library registration
#   iam.tf            crawler role + cross-account reader roles + health-check role
#   sqs.tf            health-check Lambda DLQ
#   lambda.tf         health-check Lambda + log group + archive
#   eventbridge.tf    health-check schedule + Glue crawler state forwarder
#   cloudwatch.tf     health-check alarms + CUR freshness alarm + dashboard
#
# Lambda Python source: lambda/health_check.py
# Documentation:        README.md + docs/EDGE_CASES.md + CHANGELOG.md
###############################################################################
