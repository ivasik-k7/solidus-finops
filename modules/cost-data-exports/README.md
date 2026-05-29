# cost-data-exports

CUR 2.0 + (optionally) FOCUS 1.0 exports via AWS BCM Data Exports, landing in a CMK-encrypted S3 bucket, queryable through an Athena workgroup with a Glue crawler that discovers schema and partitions.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Naming prefix. |
| `bucket_name` | string | — | Bucket name (root caller derives `<name_prefix>-cost-data-<account_id>`). |
| `kms_key_arn` | string | — | CMK used for bucket + Athena results + Glue crawler. |
| `account_id` | string | — | AWS account ID (for bucket policy `aws:SourceAccount`). |
| `enable_focus_export` | bool | — | Emit FOCUS 1.0 alongside CUR 2.0. |
| `enable_athena_workgroup` | bool | — | Provision Athena workgroup + Glue DB + crawler. |
| `cost_data_retention_days` | number | — | Days in S3 Standard before tiering current versions to Glacier Instant Retrieval. |
| `cost_data_expiration_days` | number | — | Total retention before expiration. |
| `default_tags` | map(string) | — | Tags applied to every resource. |

## Outputs

| Name | Description |
|---|---|
| `bucket_name` | Cost-data bucket name. |
| `bucket_arn` | Cost-data bucket ARN. |
| `cur2_export_arn` | ARN of the CUR 2.0 BCM Data Export. |
| `focus_export_arn` | ARN of the FOCUS 1.0 BCM Data Export (null if disabled). |
| `athena_workgroup_name` | Athena workgroup name (null if Athena disabled). |
| `athena_database_name` | Glue/Athena database name (null if Athena disabled). |
| `cur2_table_name` | Glue table name the crawler creates (`<namespace>_<env>_<stack>_data`). Use this in Athena queries. |
| `cur_crawler_name` | Glue crawler name. |

## Design notes

- **Real CUR 2.0** via `aws_bcmdataexports_export` with `query_statement = "SELECT * FROM COST_AND_USAGE_REPORT"` and the recommended table configuration (`HOURLY` granularity, `INCLUDE_RESOURCES`, `INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY`, `INCLUDE_SPLIT_COST_ALLOCATION_DATA`). FOCUS 1.0 uses the same BCM Data Exports primitive.
- **No `us-east-1` provider alias required.** BCM Data Exports works in any region (unlike the legacy `aws_cur_report_definition`).
- **Glue crawler discovers schema and partitions.** CUR 2.0's S3 path uses `BILLING_PERIOD=YYYY-MM` as the partition; the crawler creates the table with a deterministic prefix and discovers partitions on every daily run.
- **Operational delay on first apply.** BCM Data Exports delivers the first CUR ~24 hours after the export is created; the crawler runs daily and discovers it on the next tick. **Athena queries are non-functional for ~24–48 hours after the very first `terraform apply`.** Subsequent applies don't have this delay.
- **Lifecycle splits current vs. noncurrent versions.** Current versions tier to `GLACIER_IR` (Athena-queryable, ~68% cheaper than Standard). Noncurrent versions go to `DEEP_ARCHIVE` quickly and expire at 90 days. Deep Archive on current versions would break Athena.
- **Double destroy protection.** `force_destroy = false` blocks `aws s3 rb`; `lifecycle.prevent_destroy = true` blocks `terraform destroy`. Both must be edited intentionally to retire the bucket.
- **KMS policy grants both billing service principals.** `billingreports.amazonaws.com` (legacy CUR, still needed for the API surface) and `bcm-data-exports.amazonaws.com` (CUR 2.0 + FOCUS) each receive scoped `GenerateDataKey` / `Decrypt` with `aws:SourceAccount` conditions.

## Querying the data

After the crawler's first successful run, the CUR 2.0 table is at:

```
<athena_database_name>.<cur2_table_name>
```

Both values are exposed as module outputs and surfaced at the root. Use the standard CUR 2.0 column names (`line_item_unblended_cost`, `line_item_resource_id`, `product_servicecode`, `resource_tags['user_<TagKey>']`, …) and the `billing_period` partition key:

```sql
SELECT product_servicecode, SUM(line_item_unblended_cost)
FROM <db>.<table>
WHERE billing_period = date_format(current_date, '%Y-%m')
GROUP BY 1
ORDER BY 2 DESC;
```

The [`finops-metrics`](../finops-metrics/) and [`tag-governance`](../tag-governance/) modules consume this contract.
