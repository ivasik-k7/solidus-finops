# savings-coverage-reporter

A weekly Lambda that queries Cost Explorer for RI and Savings Plan coverage + utilization, and publishes a structured report to the events bus.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic for the report. |
| `kms_key_arn` | string | — | CMK for log groups + Lambda env vars. |
| `log_retention_days` | number | — | CloudWatch log retention. |
| `report_cron` | string | — | EventBridge cron expression (UTC, six-field). |
| `target_coverage_pct` | number | — | Target RI/SP coverage; reports below this are flagged. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

## Outputs

| Name | Description |
|---|---|
| `lambda_arn` | Reporter Lambda ARN. |
| `dlq_arn` | SQS DLQ ARN. |

## Design notes

- **Coverage AND utilization.** Coverage too low = leaving discount on the table. Utilization too low = paying for unused commitments (a 3-year RI at 50% utilization is worse than on-demand). Both must be tracked.
- **Amortized rates.** Cost Explorer's `*SavingsPlans*` and `*Reservation*` APIs return amortized data; the report uses it so committed-spend discounts are properly reflected.
- **DLQ + alarms.** Same pattern as the other Lambdas: failed invocations to SQS, `Lambda Errors` and DLQ-depth alarms fire to the events topic.
- **Cost Explorer API is throttled.** If a run is rate-limited, the next week's tick recovers. Manual invocation is also fine.
