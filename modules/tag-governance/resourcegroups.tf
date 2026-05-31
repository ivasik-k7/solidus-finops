###############################################################################
# Allocation Resource Groups
#
# For each entry in var.allocation_resource_groups, provision a tag-based
# Resource Group so the AWS Console (and Resource Explorer) can filter by
# the allocation dimension out-of-the-box.
###############################################################################

resource "aws_resourcegroups_group" "allocation" {
  for_each = var.allocation_resource_groups

  name        = "${var.name_prefix}-${each.key}"
  description = "FinOps allocation group: ${each.value.tag_key} in [${join(", ", each.value.tag_values)}]"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = each.value.tag_key
          Values = each.value.tag_values
        }
      ]
    })
  }

  tags = var.default_tags
}
