###############################################################################
# Locals — channel synthesis + dispatcher manifest construction
#
# Three layers:
#   1. Legacy → new bridge: notification_emails / slack_webhook_url /
#      teams_webhook_url get folded into the channels object when the new
#      schema is empty.
#   2. effective_channels — the actual channel list the rest of the module reads.
#   3. dispatcher_manifest — JSON payload the dispatcher Lambda consumes at
#      runtime, with every channel resolved to a secret ARN where needed.
###############################################################################

locals {
  # Legacy → new bridge. Only used when `channels` is empty.
  legacy_channels = {
    email = length(var.notification_emails) > 0 ? [
      { addresses = var.notification_emails, min_severity = "info" }
    ] : []
    slack = var.slack_webhook_url == null ? [] : [
      { webhook_url = var.slack_webhook_url, label = "slack-legacy", min_severity = "info", webhook_secret_arn = null }
    ]
    teams = var.teams_webhook_url == null ? [] : [
      { webhook_url = var.teams_webhook_url, label = "teams-legacy", min_severity = "info", webhook_secret_arn = null }
    ]
    pagerduty        = []
    opsgenie         = []
    generic_webhooks = []
    sqs              = []
  }

  channels_empty = (
    length(coalesce(var.channels.email, [])) == 0 &&
    length(coalesce(var.channels.slack, [])) == 0 &&
    length(coalesce(var.channels.teams, [])) == 0 &&
    length(coalesce(var.channels.pagerduty, [])) == 0 &&
    length(coalesce(var.channels.opsgenie, [])) == 0 &&
    length(coalesce(var.channels.generic_webhooks, [])) == 0 &&
    length(coalesce(var.channels.sqs, [])) == 0
  )

  effective_channels = local.channels_empty ? local.legacy_channels : {
    email            = coalesce(var.channels.email, [])
    slack            = coalesce(var.channels.slack, [])
    teams            = coalesce(var.channels.teams, [])
    pagerduty        = coalesce(var.channels.pagerduty, [])
    opsgenie         = coalesce(var.channels.opsgenie, [])
    generic_webhooks = coalesce(var.channels.generic_webhooks, [])
    sqs              = coalesce(var.channels.sqs, [])
  }

  # Email destinations expanded to one (channel × address) pair per row.
  email_subscriptions = flatten([
    for ch in local.effective_channels.email : [
      for addr in ch.addresses : { address = addr, min_severity = ch.min_severity }
    ]
  ])

  # Channels needing a Secrets Manager secret (inline value provided).
  slack_inline_secrets = {
    for idx, ch in local.effective_channels.slack :
    "slack-${idx}" => ch if ch.webhook_url != null
  }
  teams_inline_secrets = {
    for idx, ch in local.effective_channels.teams :
    "teams-${idx}" => ch if ch.webhook_url != null
  }
  pagerduty_inline_secrets = {
    for idx, ch in local.effective_channels.pagerduty :
    "pagerduty-${idx}" => ch if ch.integration_key != null
  }
  opsgenie_inline_secrets = {
    for idx, ch in local.effective_channels.opsgenie :
    "opsgenie-${idx}" => ch if ch.api_key != null
  }
  webhook_inline_secrets = {
    for idx, ch in local.effective_channels.generic_webhooks :
    "webhook-${idx}" => ch if ch.url != null
  }

  any_dispatch_channels = (
    length(local.effective_channels.slack) > 0 ||
    length(local.effective_channels.teams) > 0 ||
    length(local.effective_channels.pagerduty) > 0 ||
    length(local.effective_channels.opsgenie) > 0 ||
    length(local.effective_channels.generic_webhooks) > 0 ||
    length(local.effective_channels.sqs) > 0
  )

  # Dispatcher consumes a "manifest" — all channels + their resolved secret
  # ARNs — as a JSON env var.
  dispatcher_manifest = jsonencode({
    slack = [
      for idx, ch in local.effective_channels.slack : {
        label              = ch.label
        min_severity       = ch.min_severity
        webhook_secret_arn = ch.webhook_url != null ? aws_secretsmanager_secret.slack[tostring(idx)].arn : ch.webhook_secret_arn
      }
    ]
    teams = [
      for idx, ch in local.effective_channels.teams : {
        label              = ch.label
        min_severity       = ch.min_severity
        webhook_secret_arn = ch.webhook_url != null ? aws_secretsmanager_secret.teams[tostring(idx)].arn : ch.webhook_secret_arn
      }
    ]
    pagerduty = [
      for idx, ch in local.effective_channels.pagerduty : {
        label                      = ch.label
        min_severity               = ch.min_severity
        integration_key_secret_arn = ch.integration_key != null ? aws_secretsmanager_secret.pagerduty[tostring(idx)].arn : ch.integration_key_secret_arn
      }
    ]
    opsgenie = [
      for idx, ch in local.effective_channels.opsgenie : {
        label              = ch.label
        min_severity       = ch.min_severity
        eu_region          = ch.eu_region
        api_key_secret_arn = ch.api_key != null ? aws_secretsmanager_secret.opsgenie[tostring(idx)].arn : ch.api_key_secret_arn
      }
    ]
    generic_webhooks = [
      for idx, ch in local.effective_channels.generic_webhooks : {
        label          = ch.label
        min_severity   = ch.min_severity
        headers        = ch.headers
        url_secret_arn = ch.url != null ? aws_secretsmanager_secret.webhook[tostring(idx)].arn : ch.url_secret_arn
      }
    ]
    sqs = [
      for ch in local.effective_channels.sqs : {
        label        = ch.label
        min_severity = ch.min_severity
        queue_arn    = ch.queue_arn
      }
    ]
  })

  # All secret ARNs the dispatcher must read at runtime.
  all_secret_arns = concat(
    [for s in aws_secretsmanager_secret.slack : s.arn],
    [for s in aws_secretsmanager_secret.teams : s.arn],
    [for s in aws_secretsmanager_secret.pagerduty : s.arn],
    [for s in aws_secretsmanager_secret.opsgenie : s.arn],
    [for s in aws_secretsmanager_secret.webhook : s.arn],
    [for ch in local.effective_channels.slack : ch.webhook_secret_arn if ch.webhook_secret_arn != null],
    [for ch in local.effective_channels.teams : ch.webhook_secret_arn if ch.webhook_secret_arn != null],
    [for ch in local.effective_channels.pagerduty : ch.integration_key_secret_arn if ch.integration_key_secret_arn != null],
    [for ch in local.effective_channels.opsgenie : ch.api_key_secret_arn if ch.api_key_secret_arn != null],
    [for ch in local.effective_channels.generic_webhooks : ch.url_secret_arn if ch.url_secret_arn != null],
  )

  sqs_target_arns = [for ch in local.effective_channels.sqs : ch.queue_arn]

  metric_namespace = "FinOps/Alerting"
}
