# alerting — events-bus-as-a-service

A standalone, multi-channel event dispatcher. Reusable **outside** this framework — drop it into any Terraform project that needs intelligent alert fan-out.

```
   Publisher (your Lambda, Budgets, CloudWatch alarm, anything)
       │
       │  publish to SNS topic
       ▼
   ┌────────────────────────────────────────────────────────┐
   │  alerting module                                       │
   │                                                        │
   │   SNS topic ──── [Native email subscriptions]          │
   │      │                                                 │
   │      │ (Lambda subscription)                           │
   │      ▼                                                 │
   │   Dispatcher Lambda                                    │
   │      │  • severity inference                           │
   │      │  • DDB dedup cache lookup                       │
   │      │  • per-channel min_severity filter              │
   │      ▼                                                 │
   │   ┌──── Slack (Block Kit cards)                        │
   │   ├──── Teams (Adaptive Cards)                         │
   │   ├──── PagerDuty Events API v2                        │
   │   ├──── Opsgenie Alerts API (US / EU)                  │
   │   ├──── Generic HTTPS webhook (custom headers)         │
   │   └──── SQS queue (downstream pull)                    │
   │                                                        │
   │   DDB events table (audit log + dedup cache)           │
   └────────────────────────────────────────────────────────┘
```

## What makes this module 10/10

| Capability | Detail |
|---|---|
| **Multi-channel polymorphic schema** | 7 channel types, multiple destinations per type, each with its own min_severity filter |
| **Severity-based routing** | `info / low / medium / high / critical` — PagerDuty defaults to `min_severity = high` so noise doesn't page on-call |
| **DDB-backed deduplication** | Same fingerprint within window → suppressed (still audited). Default window 60 min over `[AlertName, severity, ResourceId]`. |
| **DDB audit log** | 1-year retention by default; every dispatched event with per-channel outcomes |
| **Inline secrets OR Secrets Manager ARNs** | Inline `webhook_url = "..."` → module creates Secrets Manager secret automatically. Or pass `webhook_secret_arn = "..."` to reference an existing secret. |
| **CMK encryption on everything** | SNS, DDB, Secrets Manager, Lambda env vars, log groups |
| **Standalone-friendly** | No hard dependency on the FinOps framework — usable as `source = "git::..."` from any project |
| **Publisher library** ([lib/finops_event.py](lib/finops_event.py)) | Copy into any Lambda to publish well-formed events with one function call |
| **Backward-compatible** | Legacy `notification_emails` / `slack_webhook_url` / `teams_webhook_url` still work; synthesized into `channels` internally |

## Standalone usage (outside the FinOps framework)

```hcl
module "events_bus" {
  source = "git::https://github.com/your-org/finops-framework-demo.git//modules/alerting?ref=v1.0.0"

  name_prefix = "myproject"
  kms_key_arn = aws_kms_key.shared.arn

  channels = {
    slack = [
      { webhook_url = var.slack_webhook,   label = "#alerts",     min_severity = "info" },
      { webhook_url = var.slack_incidents, label = "#incidents",  min_severity = "high" },
    ]
    teams = [
      { webhook_url = var.teams_webhook, label = "team-channel", min_severity = "medium" },
    ]
    pagerduty = [
      { integration_key = var.pd_key, label = "platform-oncall", min_severity = "high" },
    ]
    email = [
      { addresses = ["ops@example.com"], min_severity = "info" },
    ]
  }

  deduplication = {
    enabled        = true
    window_minutes = 30
    fingerprint_fields = ["AlertName", "Resource"]
  }

  default_tags = { Owner = "platform-team" }
}

# Publish from your own Lambda
resource "aws_lambda_function" "my_publisher" {
  # ...
  environment {
    variables = { EVENTS_TOPIC_ARN = module.events_bus.events_topic_arn }
  }
}
```

In your publisher Lambda (copy [lib/finops_event.py](lib/finops_event.py) into the function package):

```python
from finops_event import publish
import os

def handler(event, context):
    publish(
        topic_arn=os.environ["EVENTS_TOPIC_ARN"],
        subject="Database failover",
        severity="high",
        alert_name="rds-failover",
        fields={
            "Cluster": "prod-orders",
            "Region": "eu-central-1",
            "Reason": "primary-unhealthy",
        },
    )
```

## Inputs

### Core

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Prefix for all resource names |
| `kms_key_arn` | string | — | CMK for SNS, DDB, Secrets Manager, Lambda env, log groups |
| `log_retention_days` | number | `365` | CloudWatch log retention |
| `lambda_runtime` | string | `"python3.12"` | Dispatcher runtime |
| `default_tags` | map(string) | `{}` | Tags applied to all resources |

### `channels` — multi-channel schema

```hcl
channels = {
  email = [{
    addresses    = list(string)
    min_severity = "info" | "low" | "medium" | "high" | "critical"  # default "info"
  }]

  slack = [{
    webhook_url        = optional(string)        # inline → module stores in Secrets Manager
    webhook_secret_arn = optional(string)        # OR reference an existing secret
    label              = optional(string)        # for audit + Slack footer
    min_severity       = optional(string, "info")
  }]

  teams = [{
    webhook_url        = optional(string)
    webhook_secret_arn = optional(string)
    label              = optional(string)
    min_severity       = optional(string, "info")
  }]

  pagerduty = [{
    integration_key            = optional(string)
    integration_key_secret_arn = optional(string)
    label                      = optional(string)
    min_severity               = optional(string, "high")  # PD defaults to high+ only
  }]

  opsgenie = [{
    api_key            = optional(string)
    api_key_secret_arn = optional(string)
    label              = optional(string)
    eu_region          = optional(bool, false)
    min_severity       = optional(string, "high")
  }]

  generic_webhooks = [{
    url            = optional(string)
    url_secret_arn = optional(string)
    label          = string
    headers        = optional(map(string), {})  # e.g. Authorization
    min_severity   = optional(string, "info")
  }]

  sqs = [{
    queue_arn    = string
    label        = optional(string)
    min_severity = optional(string, "info")
  }]
}
```

### `deduplication`

```hcl
deduplication = {
  enabled            = optional(bool, true)
  window_minutes     = optional(number, 60)
  fingerprint_fields = optional(list(string), ["AlertName", "severity", "ResourceId"])
}
```

### `audit_log`

```hcl
audit_log = {
  enabled        = optional(bool, true)
  retention_days = optional(number, 365)
}
```

### Legacy compat (still works, prefer `channels`)

| Name | Replaces |
|---|---|
| `notification_emails` | `channels.email[].addresses` |
| `slack_webhook_url` | `channels.slack[].webhook_url` |
| `teams_webhook_url` | `channels.teams[].webhook_url` |

## Outputs

| Name | Description |
|---|---|
| `events_topic_arn` | SNS topic ARN — publishers write here |
| `events_topic_name` | SNS topic name |
| `dispatcher_lambda_arn` | Dispatcher Lambda ARN |
| `dispatcher_dlq_arn` | Dispatcher DLQ ARN |
| `events_table_name` | DDB table with AUDIT + DEDUP rows |
| `channel_secret_arns` | Map of channel-key → Secrets Manager ARN (only for channels where inline value was supplied) |

Plus backward-compat aliases: `chat_notifier_lambda_arn`, `chat_notifier_dlq_arn`, `slack_webhook_secret_arn`, `teams_webhook_secret_arn`.

## Message schema (what publishers should send)

```json
{
  "severity": "info" | "low" | "medium" | "high" | "critical",
  "AlertName": "stable-identifier-used-for-dedup",
  "ResourceId": "optional but recommended for dedup",
  "Any other fields": "rendered as labelled rows in Slack/Teams"
}
```

Send this as the SNS `Message` body. The SNS `Subject` becomes the card title.

If you only have a flat string, that works too — the dispatcher will use it as the message body and infer severity from the subject keywords.

## How severity is inferred

Priority order:
1. Explicit `severity` field in the parsed payload → wins
2. Subject contains "critical" / "page" / "incident" / "outage" → `critical`
3. Subject contains "error" / "alarm" / "exceeded" / "anomaly" / "breach" → `high`
4. Subject contains "warning" / "forecast" / "approaching" / "drift" → `medium`
5. Subject contains "report" / "digest" / "weekly" / "coverage" / "summary" → `info`
6. Default → `info`

## CloudWatch metrics emitted

Under namespace `FinOps/Alerting`:

| Metric | Meaning |
|---|---|
| `DispatchedCount` | Successful deliveries per Lambda invocation |
| `SuppressedCount` | Events suppressed by dedup cache |
| `FailedCount` | Channel deliveries that errored |

Plus the per-Lambda Errors + DLQ-depth alarms you get with every framework Lambda.

## Migration from the old chat-notifier

The old module exposed only `notification_emails`, `slack_webhook_url`, `teams_webhook_url` and ran a chat-notifier Lambda. Migration paths:

**No code change (legacy compat)**: keep the three old variables; the module synthesises a single Slack + single Teams channel internally, both at `min_severity = "info"`.

**Recommended (new schema)**: move to `channels = { slack = [...], teams = [...], email = [...] }`. You get severity filtering, multiple destinations per type, and the PagerDuty/Opsgenie/webhook/SQS channels that weren't previously available.

**Output names**: the new module preserves the old output names (`chat_notifier_lambda_arn`, `chat_notifier_dlq_arn`, `slack_webhook_secret_arn`, `teams_webhook_secret_arn`) so consumers of those outputs don't break.

## When to extend

These were intentionally left out of this version — they're real follow-ups:

- **Jira / ServiceNow ticket creation** — additional channel adapters; needs each tool's REST endpoint + auth pattern
- **Owner-aware routing** — extract `Owner` field from payload, look up Slack handle in DDB, DM that person
- **Interactive action buttons** (Acknowledge / Snooze / Escalate) — needs API Gateway receiver Lambda; biggest UX win for production paging
- **Daily digest mode** — bulk low-severity events into a single morning summary
- **Recipient management API** — Lambda + API Gateway to add/remove subscribers without `terraform apply`
- **Test-event endpoint** — `aws lambda invoke` a "fire test event" Lambda to verify all channels end-to-end
