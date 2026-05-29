# alerting

The events bus that all other FinOps modules publish to. Provides:

- A single KMS-encrypted SNS topic (`<name_prefix>-alerts`) for budget alerts, anomaly events, governance findings, idle/scheduler/coverage reports.
- Optional Slack/Teams chat notifier Lambda. Webhook URLs are stored in Secrets Manager (CMK-encrypted), fetched at runtime, cached per warm container.
- DLQ + CloudWatch error and DLQ-depth alarms on the notifier Lambda.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix (`<namespace>-<environment>-<stack_name>`). |
| `kms_key_arn` | string | — | CMK used for SNS, Secrets Manager, log groups. |
| `notification_emails` | list(string) | `[]` | Emails subscribed to the topic. |
| `slack_webhook_url` | string (sensitive) | `null` | Slack webhook. If set, written to Secrets Manager. |
| `teams_webhook_url` | string (sensitive) | `null` | Teams webhook. If set, written to Secrets Manager. |
| `log_retention_days` | number | `2557` | CloudWatch log retention for the notifier. |
| `default_tags` | map(string) | `{}` | Tags applied to every resource in the module. |

## Outputs

| Name | Description |
|---|---|
| `events_topic_arn` | SNS topic ARN. Publish here from external workspaces too. |
| `events_topic_name` | SNS topic name. |
| `chat_notifier_lambda_arn` | Chat notifier Lambda ARN (null if neither webhook is set). |
| `chat_notifier_dlq_arn` | SQS DLQ ARN for the notifier (null if not deployed). |
| `slack_webhook_secret_arn` | Secrets Manager ARN holding the Slack URL (null if unset). |
| `teams_webhook_secret_arn` | Secrets Manager ARN holding the Teams URL (null if unset). |

## Design notes

- One topic, many channels. Keeps governance and audit simple.
- The alarm pair (Lambda Errors + DLQ depth) both fire to the topic. If the chat notifier itself is the failure point, email subscribers still receive the alarm directly from SNS.
- Webhook URLs intentionally never appear in Lambda env vars in plaintext — only secret ARNs do. The Python loader caches the resolved URL per warm container, so a hot Lambda pays Secrets Manager once.
- Secret recovery window is 30 days to protect against accidental destroy.
