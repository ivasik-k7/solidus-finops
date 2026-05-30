# The provider's region and credentials come from the TFE workspace environment.
# Do NOT hardcode credentials here.
#
# Required TFE workspace environment variables:
#   AWS_ACCESS_KEY_ID         (or assumed-role via dynamic credentials)
#   AWS_SECRET_ACCESS_KEY     (or assumed-role via dynamic credentials)
#   AWS_SESSION_TOKEN         (if using temporary credentials)
#   AWS_DEFAULT_REGION        (or set var.aws_primary_region)

provider "aws" {
  region = var.aws_primary_region

  # Default tags applied to every resource the provider creates.
  # The framework's locals.tf computes the full tag set; we surface it here so
  # ad-hoc resources also pick them up.
  default_tags {
    tags = local.default_tags
  }
}

# A us-east-1 provider alias was previously declared for CUR v1 + legacy Cost
# Anomaly Detection endpoints. CUR 2.0 via BCM Data Exports is region-agnostic
# at the Terraform layer (the API is global with a us-east-1 endpoint but does
# not require a separate provider). Removed in v0.2.x.
#
# If you need to reach a us-east-1-only service (e.g. CloudFront, ACM for
# CloudFront), add a `provider "aws" { alias = "us_east_1" ... }` block back
# alongside this one and pass `providers = { aws = aws.us_east_1 }` to the
# consuming module.
