# instance-scheduler

Tag-driven EC2 start/stop scheduler. **Opt-in by tag. Off at the root by default.**

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for scheduling notifications. |
| `kms_key_arn` | string | — | CMK for log groups + Lambda env vars. |
| `log_retention_days` | number | — | CloudWatch log retention. |
| `opt_in_tag_key` | string | — | Tag key that opts an instance INTO scheduling (default `Schedule`). |
| `schedules` | map(object{start_cron,stop_cron}) | — | Named schedules. Cron expressions in UTC. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

## Outputs

| Name | Description |
|---|---|
| `lambda_arn` | Scheduler Lambda ARN. |
| `dlq_arn` | SQS DLQ ARN. |

## Design notes

- **Opt-IN, not opt-out.** An instance is scheduled only if it carries the opt-in tag whose value matches a known schedule name (e.g. `Schedule=office-hours-cet`). Anything untagged or with an unrecognized value is left alone. This is far safer in a bank than the typical opt-out scheduler where one untagged production DB becomes an outage.
- **No RDS support yet.** IAM grants `ec2:*` only. RDS scheduling is a roadmap item.
- **5-minute tick.** The Lambda runs every 5 minutes via EventBridge. Each tick reconciles instance state against the schedule windows defined at apply time.
- **DLQ + alarms.** Failed invocations go to SQS; both `Lambda Errors` and DLQ-depth alarms fire to the events topic.
