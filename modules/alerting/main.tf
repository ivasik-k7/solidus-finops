###############################################################################
# alerting — module entry point
#
# A standalone, multi-channel event dispatcher. Reusable outside the
# Solidus FinOps framework: this module has no hard dependency on any other
# module in this repo. Publishers fire to the SNS topic; the dispatcher
# Lambda routes by severity to all enabled channels, deduplicates repeated
# alerts, and writes an audit trail to DynamoDB.
#
# Channels supported (each polymorphic, multiple instances per type):
#   - email           AWS SNS native; first 1k/mo free
#   - slack           Incoming webhooks; rich Block Kit cards
#   - teams           Incoming webhooks; Adaptive Cards
#   - pagerduty       Events API v2; production paging
#   - opsgenie        Alerts API; US or EU region
#   - generic_webhook Any HTTPS endpoint (custom integrations)
#   - sqs             Queue ARN; downstream consumers pull at their pace
#
# Per-channel filtering by severity (info / low / medium / high / critical)
# lets you route critical alerts to PagerDuty while low-severity ones go
# to an info-only Slack channel.
#
# Backward compat: notification_emails, slack_webhook_url, teams_webhook_url
# still work — they're synthesized into `channels` at module-locals time.
#
# This file intentionally contains no resources. Module content is split
# across:
#
#   versions.tf      provider + Terraform version requirements
#   variables.tf     all input variables
#   outputs.tf       all outputs (including pre-v0.2 compatibility aliases)
#   locals.tf        legacy → new channel bridge, dispatcher manifest
#   data.tf          data sources + SNS topic policy document
#   sns.tf           events SNS topic + policy + subscriptions
#   secrets.tf       per-channel Secrets Manager entries
#   dynamodb.tf      audit + dedup events table
#   sqs.tf           dispatcher DLQ
#   iam.tf           dispatcher Lambda role + policy
#   lambda.tf        dispatcher Lambda + log group + archive_file + permission
#   cloudwatch.tf    dispatcher self-health alarms
#
# Lambda Python source: lambda/dispatcher.py + lambda/channels.py
# Documentation:        README.md + docs/EDGE_CASES.md + CHANGELOG.md
###############################################################################
