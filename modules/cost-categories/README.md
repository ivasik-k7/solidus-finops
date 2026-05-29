# cost-categories

AWS Cost Categories defined as code. The rule set lives in git, the evaluation happens on the bill, and the result is queryable in Cost Explorer and CUR.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `cost_categories` | map(object) | — | Category definitions; see schema below. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

### `cost_categories` schema

```hcl
cost_categories = {
  <CategoryName> = {
    rule_version  = optional, default "CostCategoryExpression.v1"
    default_value = optional, default "unallocated"
    rules = list({
      value = string  # the category value the rule assigns
      rule  = {
        tags      = optional { key, values, match_options }
        dimension = optional { key, values, match_options }
      }
    })
  }
}
```

## Outputs

| Name | Description |
|---|---|
| `category_arns` | Map of category name → ARN. Use in CUR/Athena joins. |
| `category_effective_starts` | Map of category name → effective start timestamp. |

## Design notes

- **Chargeback reproducibility.** Every change to the variable creates a new Cost Category version in AWS. The combination of `git log` + the AWS `effective_start` lets an auditor reproduce any historical month's allocation deterministically.
- **No nested AND/OR yet.** This module supports flat tag/dimension rules. For nested expressions (`{ and: [...], not: ... }`), extend the dynamic blocks in [main.tf](main.tf).
- **`unallocated` default value** is the FinOps convention for the residual bucket — what doesn't match any rule.
