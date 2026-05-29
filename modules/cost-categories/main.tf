###############################################################################
# Cost Categories module
#
# AWS Cost Categories let you create dimensions in Cost Explorer / CUR that
# group spend by arbitrary business rules. They are the cleanest way to encode
# chargeback allocation logic, because:
#
#   1. The rules are evaluated by AWS on the bill, not by your BI tool.
#   2. They are queryable in Cost Explorer and CUR.
#   3. They are versioned (every change creates a new version) and reproducible.
#   4. They are auditable: the entire rule set lives in Terraform under git.
#
# This module accepts an arbitrarily-shaped `cost_categories` map and
# provisions one Cost Category per entry.
#
# Example input:
#
#   cost_categories = {
#     "BusinessUnit" = {
#       rule_version = "CostCategoryExpression.v1"
#       default_value = "unallocated"
#       rules = [
#         {
#           value = "retail-banking"
#           rule = {
#             tags = {
#               key            = "BusinessUnit"
#               values         = ["retail-banking"]
#               match_options  = ["EQUALS"]
#             }
#           }
#         },
#         {
#           value = "investment-banking"
#           rule = {
#             tags = {
#               key            = "BusinessUnit"
#               values         = ["investment-banking", "ib", "markets"]
#               match_options  = ["EQUALS"]
#             }
#           }
#         },
#       ]
#     }
#   }
###############################################################################

variable "cost_categories" {
  description = "Map of Cost Category definitions. See module README."
  type        = any
}

variable "default_tags" { type = map(string) }

###############################################################################
# Cost Categories
#
# Because the AWS provider's aws_ce_cost_category resource uses nested blocks
# rather than a JSON spec, we keep this thin: callers pass structured input
# and we map it to the resource. For more advanced rule shapes (nested
# AND/OR expressions), extend this module.
###############################################################################

resource "aws_ce_cost_category" "this" {
  for_each = var.cost_categories

  name         = each.key
  rule_version = lookup(each.value, "rule_version", "CostCategoryExpression.v1")
  default_value = lookup(each.value, "default_value", "unallocated")

  dynamic "rule" {
    for_each = each.value.rules
    content {
      value = rule.value.value

      rule {
        # Support tag-based rules (the most common pattern)
        dynamic "tags" {
          for_each = lookup(rule.value.rule, "tags", null) != null ? [rule.value.rule.tags] : []
          content {
            key           = tags.value.key
            values        = tags.value.values
            match_options = tags.value.match_options
          }
        }

        # Support dimension-based rules (e.g. by linked account)
        dynamic "dimension" {
          for_each = lookup(rule.value.rule, "dimension", null) != null ? [rule.value.rule.dimension] : []
          content {
            key           = dimension.value.key
            values        = dimension.value.values
            match_options = dimension.value.match_options
          }
        }
      }
    }
  }

  tags = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "category_arns" {
  description = "Map of cost category name -> ARN. Useful for joining in CUR/Athena queries."
  value       = { for k, v in aws_ce_cost_category.this : k => v.arn }
}

output "category_effective_starts" {
  description = "Map of cost category name -> effective start timestamp."
  value       = { for k, v in aws_ce_cost_category.this : k => v.effective_start }
}
