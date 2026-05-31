###############################################################################
# Locals — namespace, mandatory-tag resolution, Config rule chunking
###############################################################################

locals {
  metric_namespace = "FinOps/TagGovernance"
  ssm_prefix       = "/${var.name_prefix}/tag-governance"

  mandatory_tag_keys_from_required = [for t in var.required_tags : t.key]

  # Prefer taxonomy entries marked level="mandatory" when the caller supplied
  # taxonomy; otherwise fall back to required_tags (preserves the existing contract).
  mandatory_tag_keys = length(var.tag_taxonomy) > 0 ? [
    for k, v in var.tag_taxonomy : k if v.level == "mandatory"
  ] : local.mandatory_tag_keys_from_required

  deploy_untagged_report = (
    var.enable_untagged_cost_report
    && var.athena_workgroup_name != null
    && var.athena_database_name != null
    && length(local.mandatory_tag_keys) > 0
  )

  # AWS Config's REQUIRED_TAGS managed rule accepts up to 6 tag keys per
  # rule. Chunk the input into groups of 6 and provision one rule per chunk
  # so callers can require an arbitrary number of tags without silent
  # truncation.
  required_tag_chunks = chunklist(var.required_tags, 6)

  required_tag_chunk_params = {
    for chunk_idx, chunk in local.required_tag_chunks :
    chunk_idx => merge(
      {
        for i, t in chunk :
        "tag${i + 1}Key" => t.key
      },
      {
        for i, t in chunk :
        "tag${i + 1}Value" => join(",", t.allowed_values) if length(t.allowed_values) > 0
      },
    )
  }
}
