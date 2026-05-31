###############################################################################
# EventBridge — Config compliance fan-out + tag drift audit
#
# Two rules:
#   1. tag_compliance — catches Config "Rules Compliance Change" events
#      flagged NON_COMPLIANT and forwards a structured digest to SNS.
#   2. tag_drift     — catches the unified "Tag Change on Resource" event
#      filtered to allocation-critical tag keys.
###############################################################################

# ---------------------------------------------------------------------------
# Config compliance change → SNS
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "tag_compliance" {
  count = length(var.required_tags) > 0 ? 1 : 0

  name        = "${var.name_prefix}-tag-compliance"
  description = "FinOps tag compliance change events"

  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [for r in aws_config_config_rule.required_tags : r.name]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "tag_compliance_to_sns" {
  count = length(var.required_tags) > 0 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.tag_compliance[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      account      = "$.detail.awsAccountId"
      region       = "$.detail.awsRegion"
      resourceType = "$.detail.resourceType"
      resourceId   = "$.detail.resourceId"
      ruleName     = "$.detail.configRuleName"
      compliance   = "$.detail.newEvaluationResult.complianceType"
    }
    input_template = <<EOF
{
  "severity": "medium",
  "AlertName": "FinOps tag non-compliance",
  "AccountId": <account>,
  "Region": <region>,
  "ResourceType": <resourceType>,
  "ResourceId": <resourceId>,
  "ConfigRuleName": <ruleName>,
  "Compliance": <compliance>
}
EOF
  }
}

# ---------------------------------------------------------------------------
# Tag drift → SNS (allocation-critical mutations only)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "tag_drift" {
  count = var.enable_tag_drift_detection && length(var.tag_drift_watched_keys) > 0 ? 1 : 0

  name        = "${var.name_prefix}-tag-drift"
  description = "Mutations of allocation-critical tag keys (audit trail)"

  event_pattern = jsonencode({
    source        = ["aws.tag"]
    "detail-type" = ["Tag Change on Resource"]
    detail = {
      changed-tag-keys = var.tag_drift_watched_keys
    }
  })

  tags = var.default_tags
}

resource "aws_cloudwatch_event_target" "tag_drift_to_sns" {
  count = var.enable_tag_drift_detection && length(var.tag_drift_watched_keys) > 0 ? 1 : 0

  rule      = aws_cloudwatch_event_rule.tag_drift[0].name
  target_id = "send-to-sns"
  arn       = var.events_topic_arn

  input_transformer {
    input_paths = {
      account      = "$.account"
      region       = "$.region"
      service      = "$.detail.service"
      resourceType = "$.detail.resource-type"
      resourceArn  = "$.resources[0]"
      changedKeys  = "$.detail.changed-tag-keys"
      newTags      = "$.detail.tags"
      version      = "$.detail.version"
    }
    input_template = <<EOF
{
  "severity": "medium",
  "AlertName": "FinOps allocation-tag mutation",
  "AccountId": <account>,
  "Region": <region>,
  "Service": <service>,
  "ResourceType": <resourceType>,
  "ResourceArn": <resourceArn>,
  "ChangedTagKeys": <changedKeys>,
  "NewTags": <newTags>,
  "Version": <version>
}
EOF
  }
}

# ---------------------------------------------------------------------------
# Untagged-cost report schedule
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "untagged_cost" {
  count               = local.deploy_untagged_report ? 1 : 0
  name                = "${var.name_prefix}-untagged-cost-report"
  schedule_expression = "cron(${var.untagged_cost_report_cron})"
  tags                = var.default_tags
}

resource "aws_cloudwatch_event_target" "untagged_cost" {
  count     = local.deploy_untagged_report ? 1 : 0
  rule      = aws_cloudwatch_event_rule.untagged_cost[0].name
  target_id = "untagged-cost"
  arn       = aws_lambda_function.untagged_cost[0].arn
}

resource "aws_lambda_permission" "untagged_cost_events" {
  count         = local.deploy_untagged_report ? 1 : 0
  statement_id  = "AllowEventsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.untagged_cost[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.untagged_cost[0].arn
}
