###############################################################################
# Anomaly Detection module
#
# Service-level Cost Anomaly Detection monitor + one shared subscription.
# Single-account scope: a linked-account monitor would be a no-op here, so it
# is intentionally absent.
###############################################################################

variable "name_prefix"       { type = string }
variable "events_topic_arn"  { type = string }
variable "min_impact_amount" { type = number }
variable "min_impact_pct"    { type = number }
variable "default_tags"      { type = map(string) }

###############################################################################
# Service-level monitor — catches anomalous spend in any single service.
###############################################################################

resource "aws_ce_anomaly_monitor" "service" {
  name              = "${var.name_prefix}-monitor-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = var.default_tags
}

###############################################################################
# Subscription — one threshold expression, routed to the events topic.
#
# Alert only when both absolute impact and percentage impact cross the bar.
# This avoids noise from small workloads with high percentage variance.
###############################################################################

resource "aws_ce_anomaly_subscription" "main" {
  name      = "${var.name_prefix}-anomaly-subscription"
  frequency = "IMMEDIATE"

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service.arn,
  ]

  subscriber {
    type    = "SNS"
    address = var.events_topic_arn
  }

  threshold_expression {
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [tostring(var.min_impact_amount)]
      }
    }
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [tostring(var.min_impact_pct)]
      }
    }
  }

  tags = var.default_tags
}

###############################################################################
# Outputs
###############################################################################

output "monitor_arns" {
  value = [aws_ce_anomaly_monitor.service.arn]
}

output "subscription_arn" {
  value = aws_ce_anomaly_subscription.main.arn
}
