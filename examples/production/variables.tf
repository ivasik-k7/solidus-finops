variable "slack_webhook_url" {
  description = "Slack incoming webhook URL. Set as SENSITIVE in TFE workspace."
  type        = string
  default     = null
  sensitive   = true
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL. Set as SENSITIVE in TFE workspace."
  type        = string
  default     = null
  sensitive   = true
}
