# optimization-services

Enrolls the account in two free AWS optimization services.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enable_compute_optimizer` | bool | — | Enroll in AWS Compute Optimizer (rightsizing recs for EC2/EBS/Lambda/ASG). |
| `enable_cost_optimization_hub` | bool | — | Enroll in AWS Cost Optimization Hub (consolidated savings dashboard). |

## Outputs

| Name | Description |
|---|---|
| `compute_optimizer_status` | Compute Optimizer enrollment status (null if disabled). |
| `cost_optimization_hub_enrolled` | Whether the Hub was enrolled. |

## Design notes

- **Free services.** Both default to on. Compute Optimizer's *enhanced infrastructure metrics* (CloudWatch agent data, 93-day lookback) is a separate paid feature and is NOT enabled here.
- **Single-account scope.** `include_member_accounts = false` is hardcoded — enrolling member accounts is an org-management decision that belongs elsewhere.
- **Hub savings shown after discounts.** `savings_estimation_mode = "AfterDiscounts"` means recommendations reflect what you'd actually save given your existing RIs/SPs — not the gross on-demand savings.
