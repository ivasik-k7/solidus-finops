# cost-data-exports — the FinOps data plane

A complete, audit-friendly cost data pipeline:

```
   AWS Billing service
        │
        │ CUR 2.0 + FOCUS 1.0 (BCM Data Exports)
        ▼
   ┌────────────────────────────────────────────────────────────┐
   │  S3 bucket (CMK-encrypted, versioned, prevent_destroy)     │
   │  Lifecycle: 90d → Glacier IR → 7y expiry                   │
   │  Bucket policy: TLS-only, BucketOwnerEnforced               │
   └────────┬─────────────────────────────────────┬─────────────┘
            │                                     │
            │ Glue crawler                        │ Cross-account assume-role
            ▼                                     ▼
   ┌─────────────────────────┐         ┌──────────────────────────┐
   │  Glue catalog + Athena  │         │  3rd-party FinOps tool   │
   │  + named-queries library│         │  (Cloudability / etc.)   │
   │  (12+ pre-built FinOps  │         │  reads CUR via this role │
   │   queries one-click in  │         └──────────────────────────┘
   │   Athena console)       │
   └────────┬────────────────┘
            │
            ▼
   ┌────────────────────────────────────────────────────────────┐
   │  Daily health-check Lambda                                 │
   │   • CurDeliveryHours      (alarm if > 36h)                 │
   │   • CrawlerLastRunHours                                    │
   │   • AthenaQueryability    (alarm if probe fails)           │
   │   • BucketObjectCount                                      │
   │  → CloudWatch metrics + alarms + events-bus digest         │
   └────────────────────────────────────────────────────────────┘
```

## Game-changing capabilities

| Capability | What it gives |
|---|---|
| **Real CUR 2.0** via BCM Data Exports (not legacy v1) | The actual current generation; FOCUS 1.0 alongside |
| **Glue crawler with deterministic table prefix** | Table name is predictable: `<namespace>_<env>_<stack>_data` |
| **Glacier-IR lifecycle** (not Deep Archive) | Current versions stay Athena-queryable; noncurrent versions go to Deep Archive for cheap long-term retention |
| **`prevent_destroy` on the bucket** | Cannot be wiped by a stray `terraform destroy` |
| **Cross-account reader roles for 3rd-party tools** | Cloudability/CloudHealth/Vantage/Apptio onboarding in 4 lines of HCL — with optional external-ID condition, optionally Athena-capable |
| **12+ pre-built Athena named queries** | Open Athena console → Saved queries → click. No more "what's the SQL again?" Includes MoM service trends, untagged cost, data transfer breakdown, top resources, RI utilization, daily trend with 7d MA |
| **Daily health-check Lambda** | Verifies CUR delivered in last 24h, crawler succeeded, Athena queryable — alarms if any check fails |
| **CloudWatch dashboard** | CUR freshness, crawler age, Athena queryability, bucket size by storage class |
| **EventBridge → events bus** | Crawler state-changes auto-route to the events SNS topic with structured payload |
| **Custom named queries** | `extra_named_queries` variable for org-specific queries that live alongside the library |

## Inputs

### Core (always required)

| Name | Type | Description |
|---|---|---|
| `name_prefix` | string | Naming prefix |
| `bucket_name` | string | Cost-data bucket name |
| `kms_key_arn` | string | CMK for bucket + Athena results + Lambda env + log groups |
| `account_id` | string | AWS account ID (for KMS + bucket-policy conditions) |
| `enable_focus_export` | bool | Emit FOCUS 1.0 alongside CUR 2.0 |
| `enable_athena_workgroup` | bool | Provision Athena workgroup + Glue DB + crawler |
| `cost_data_retention_days` | number | Days in S3 Standard before tiering to GLACIER_IR |
| `cost_data_expiration_days` | number | Total retention before expiration |
| `default_tags` | map(string) | Tags applied to every resource |

### Optional integrations

| Name | Type | Default | Description |
|---|---|---|---|
| `events_topic_arn` | string | `null` | If set, crawler state changes + health-check digests route here |
| `log_retention_days` | number | `365` | Lambda log retention |
| `lambda_runtime` | string | `"python3.12"` | Health-check Lambda runtime |
| `cross_account_readers` | list(object) | `[]` | 3rd-party FinOps tool roles (see below) |
| `enable_health_check` | bool | `true` | Deploy the daily health-check Lambda + alarms + dashboard |
| `health_check_schedule_cron` | string | `"0 9 * * ? *"` | EventBridge cron (UTC) |
| `cur_freshness_alarm_hours` | number | `36` | Alarm if newest CUR delivery is older than this. Null disables. |
| `enable_named_queries` | bool | `true` | Register the pre-built FinOps query library in the workgroup |
| `extra_named_queries` | map(object) | `{}` | Additional named queries to add alongside the library |

### `cross_account_readers` schema

```hcl
cross_account_readers = [{
  name          = "cloudability"           # logical identifier, used in role naming
  account_id    = "165761016623"           # 3rd-party tool's AWS account ID
  external_id   = "abc...xyz"              # optional but recommended; tool provides this
  role_name     = null                     # default: "<name_prefix>-<name>-reader"
  enable_athena = false                    # also grant Athena query permissions
}]
```

For Cloudability onboarding:
1. In Cloudability's console: **Add AWS Account** → select **Cross-Account Role**. It will show its trusted account ID and generate an external ID.
2. Set those values in `cross_account_readers` and `terraform apply`.
3. Copy the role ARN from `terraform output cost_data_cross_account_reader_role_arns` back into Cloudability's wizard.

## Outputs

| Name | Description |
|---|---|
| `bucket_name` / `bucket_arn` | Cost-data S3 bucket |
| `cur2_export_arn` / `focus_export_arn` | BCM Data Export ARNs |
| `athena_workgroup_name` / `athena_database_name` | Athena targets |
| `cur2_table_name` | Glue table the crawler creates (`<namespace>_<env>_<stack>_data`) |
| `cur_crawler_name` | Glue crawler name |
| `cross_account_reader_role_arns` | Map of reader-name → IAM role ARN |
| `named_query_ids` | Map of friendly name → Athena named-query ID |
| `health_check_lambda_arn` / `health_check_dlq_arn` | Daily verifier |
| `dashboard_name` | Auto-provisioned CloudWatch dashboard |
| `metric_namespace` | `FinOps/CostDataExports` |

## The Athena named-queries library

All queries registered against the framework's workgroup; visible immediately in the Athena console under **Saved queries**. They all use `local.cur2_table_name` (the crawler-created table) and CUR 2.0's `billing_period` partition.

| Name | What it answers |
|---|---|
| `<prefix>-top-services-mtd` | Top 20 services by unblended cost, MTD |
| `<prefix>-top-services-mom` | MoM % change per service, largest absolute swings first |
| `<prefix>-cost-by-business-unit` | Cost per `BusinessUnit` tag value, MTD |
| `<prefix>-cost-by-owner` | Cost per `Owner` tag value, MTD |
| `<prefix>-untagged-cost` | Cost of resources missing `CostCenter`, by service |
| `<prefix>-ec2-by-instance-type` | EC2 spend by instance type + region |
| `<prefix>-data-transfer-breakdown` | NAT GW, inter-region, internet, VPC peering breakdown |
| `<prefix>-daily-cost-trend` | Last 30 days with 7-day moving average |
| `<prefix>-top-resources-mtd` | Top 50 individual resources by cost |
| `<prefix>-s3-by-storage-class` | S3 breakdown by storage class |
| `<prefix>-ri-utilization-snapshot` | RI-covered vs total usage by instance family |
| `<prefix>-cost-by-region` | Total cost by AWS region |

Add your own via `extra_named_queries`:

```hcl
extra_named_queries = {
  retail-bu-detail = {
    description = "Drill into retail-banking spend by service"
    query       = <<-SQL
      SELECT product_servicecode, SUM(line_item_unblended_cost) AS cost
      FROM <db>.<table>
      WHERE billing_period = date_format(current_date, '%Y-%m')
        AND resource_tags['user_BusinessUnit'] = 'retail-banking'
      GROUP BY 1 ORDER BY 2 DESC
    SQL
  }
}
```

## Health-check Lambda — what it does daily

1. **CUR freshness** — lists newest object under `cur2/` prefix, emits `CurDeliveryHours` metric. Alarm fires if > `cur_freshness_alarm_hours`.
2. **Crawler last run** — reads Glue `GetCrawler.LastCrawl.StartTime`, emits `CrawlerLastRunHours`.
3. **Athena queryability** — runs `SELECT COUNT(*) FROM <db>.<table> LIMIT 1`, emits `AthenaQueryability` (1 ok, 0 fail).
4. **Bucket object count** — emits `BucketObjectCount`.
5. **Digest** — publishes structured payload to `events_topic_arn` with severity graded by which check failed (high if no CUR at all or Athena failed; medium if stale > 24h; info otherwise).

Three CloudWatch alarms wired automatically:
- Health-check Lambda Errors
- Health-check DLQ depth
- `CurDeliveryHours > cur_freshness_alarm_hours` (the canary; alerts before users notice)

## Operational notes

- **First apply**: the Glue crawler + first CUR delivery take **~24–48h**. The health-check Lambda will alarm during this window — that's expected. Disable the freshness alarm temporarily by setting `cur_freshness_alarm_hours = null` for the first day if you want to keep the digest quieter.
- **CUR + FOCUS in one bucket**: both exports land in the same S3 bucket under different prefixes (`cur2/` and `focus10/`). Lifecycle is uniform; Athena queries only read CUR.
- **Cross-account readers work without `enable_athena = true`**: Cloudability et al. typically read CUR directly from S3, not via Athena. Only set `enable_athena = true` if your tool's onboarding wizard asks for Athena permissions.
- **Custom queries** added via `extra_named_queries` are NOT version-tracked in DDB — they live in the Athena workgroup. To version, keep the HCL definition and treat the workgroup as the source of truth.

## When to extend

These were intentionally deferred:

- **Cross-region replication for the cost-data bucket** — DR requirement for some orgs; meaningful additional storage cost
- **CloudTrail data events on the bucket** — audit trail of every CUR read; expensive ($)
- **S3 access logs** — alternative to CloudTrail data events; cheaper but less granular
- **AWS Lake Formation governance** — fine-grained column/row-level access control on the Glue table
- **AWS Pricing API rate cache** — daily Lambda that materialises Pricing API rates into Athena for region-aware, current cost joins (today the module emits raw CUR; rate joins live in your analytics tool)
