###############################################################################
# Secrets Manager — one secret per inline-supplied webhook / key.
#
# Five channel types ship inline-secret support. Each gets a `for_each` over
# the corresponding `*_inline_secrets` local. When a caller supplies a
# pre-existing `*_secret_arn` instead, no secret is created here; the
# dispatcher reads the caller's secret directly.
#
# CKV2_AWS_57 (Secrets-Manager auto-rotation) is suppressed per-channel
# because every channel's auth mechanism is owned by a third party
# (Slack / Teams / PagerDuty / Opsgenie / opaque webhook) — rotation has
# to happen on the third-party side first.
###############################################################################

resource "aws_secretsmanager_secret" "slack" {
  # checkov:skip=CKV2_AWS_57: Slack incoming webhook URLs are immutable — Slack does not support webhook URL rotation. Rotation must be initiated by the Slack workspace admin via the Slack UI; AWS Secrets Manager cannot perform this. Operators rotate manually when needed.
  # Iterate the non-sensitive key set so tflint's static evaluator doesn't choke.
  # Look the sensitive value up from the map by key inside the resource body.
  for_each = nonsensitive(toset(keys(local.slack_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Slack webhook for channel '${local.slack_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "slack" {
  for_each      = nonsensitive(toset(keys(local.slack_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.slack[each.value].id
  secret_string = local.slack_inline_secrets[each.value].webhook_url
}

resource "aws_secretsmanager_secret" "teams" {
  # checkov:skip=CKV2_AWS_57: Microsoft Teams incoming webhook URLs are immutable — Teams does not support webhook rotation via an API. Operators rotate manually via Teams admin.
  for_each = nonsensitive(toset(keys(local.teams_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Teams webhook for channel '${local.teams_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "teams" {
  for_each      = nonsensitive(toset(keys(local.teams_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.teams[each.value].id
  secret_string = local.teams_inline_secrets[each.value].webhook_url
}

resource "aws_secretsmanager_secret" "pagerduty" {
  # checkov:skip=CKV2_AWS_57: PagerDuty integration keys are static credentials managed in the PagerDuty UI. Rotation requires re-issuing the integration on the PagerDuty side — not something AWS Secrets Manager can automate.
  for_each = nonsensitive(toset(keys(local.pagerduty_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "PagerDuty integration key for channel '${local.pagerduty_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "pagerduty" {
  for_each      = nonsensitive(toset(keys(local.pagerduty_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.pagerduty[each.value].id
  secret_string = local.pagerduty_inline_secrets[each.value].integration_key
}

resource "aws_secretsmanager_secret" "opsgenie" {
  # checkov:skip=CKV2_AWS_57: Opsgenie API keys are static credentials issued from the Opsgenie integration UI — no AWS-Secrets-Manager-driven rotation API exists on the Opsgenie side.
  for_each = nonsensitive(toset(keys(local.opsgenie_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Opsgenie API key for channel '${local.opsgenie_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "opsgenie" {
  for_each      = nonsensitive(toset(keys(local.opsgenie_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.opsgenie[each.value].id
  secret_string = local.opsgenie_inline_secrets[each.value].api_key
}

resource "aws_secretsmanager_secret" "webhook" {
  # checkov:skip=CKV2_AWS_57: Generic webhook URLs are caller-defined opaque strings — the framework has no knowledge of how to rotate them. Operators rotate manually when the downstream service issues a new URL.
  for_each = nonsensitive(toset(keys(local.webhook_inline_secrets)))

  name                    = "${var.name_prefix}-channel-${each.value}"
  description             = "Generic webhook URL for channel '${local.webhook_inline_secrets[each.value].label}'"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 30
  tags                    = var.default_tags
}

resource "aws_secretsmanager_secret_version" "webhook" {
  for_each      = nonsensitive(toset(keys(local.webhook_inline_secrets)))
  secret_id     = aws_secretsmanager_secret.webhook[each.value].id
  secret_string = local.webhook_inline_secrets[each.value].url
}
