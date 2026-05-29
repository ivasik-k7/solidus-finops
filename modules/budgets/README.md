# budgets

Polymorphic AWS Budgets driven by a single map. One `aws_budgets_budget` resource handles all scopes via dynamic `cost_filter` blocks.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `events_topic_arn` | string | — | SNS topic that budget notifications publish to. |
| `currency` | string | — | ISO 4217 currency code (e.g. `USD`). |
| `budgets` | map(object) | — | Polymorphic budget definitions; see schema below. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

### `budgets` schema

```hcl
budgets = {
  <key> = {
    scope  = "account" | "service" | "tag" | "cost_category"
    amount = number
    target = optional, required for scope != "account":
      - service:        { service        = "Amazon EC2 - Compute" }
      - tag:            { tag_key        = "BusinessUnit", tag_value = "retail-banking" }
      - cost_category:  { category_name  = "BusinessUnit", category_value = "retail-banking" }
  }
}
```

Each budget fires notifications at 50%, 80%, 100% actual and 100% forecast.

## Outputs

| Name | Description |
|---|---|
| `budget_ids` | Map of budget key → AWS Budgets resource ID. |
| `budget_names` | Map of budget key → budget name (useful for Budget Actions). |

## Design notes

- **Dynamic start.** `time_period_start` is computed from `timestamp()` at apply time and then ignored on subsequent plans via `lifecycle { ignore_changes }`, so the anchor month never drifts and never produces perpetual diffs.
- **Omit, don't toggle.** To skip a scope, just don't include an entry for it. The root module gates the whole module behind `length(var.budgets) > 0`.
- **Cost-category scope** requires the matching `cost_categories` entry to already exist; AWS evaluates the filter against the current category definition at notification time.
