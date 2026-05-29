# anomaly-detection

A service-level AWS Cost Anomaly Detection monitor wired to the events bus.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic that anomaly alerts publish to. |
| `min_impact_amount` | number | — | Minimum daily absolute impact (in budget currency) to trigger. |
| `min_impact_pct` | number | — | Minimum daily % variance, ANDed with `min_impact_amount`. |
| `default_tags` | map(string) | — | Tags applied to every resource in the module. |

## Outputs

| Name | Description |
|---|---|
| `monitor_arns` | List of anomaly monitor ARNs (one entry: the service monitor). |
| `subscription_arn` | ARN of the shared anomaly subscription. |

## Design notes

- **Single-account scope.** A linked-account monitor was previously included as a placeholder; it duplicated the service monitor and has been removed. For payer-account anomaly monitoring, deploy a separate stack with `monitor_type = "CUSTOM"`.
- **Threshold is ANDed**, not ORed: both absolute and % variance must cross the bar. This filters out high-variance low-cost workloads (e.g. a $5 service tripling to $15 doesn't page anyone).
- A future improvement is a `monitor_type = "CUSTOM"` monitor scoped to specific cost categories once those are populated.
