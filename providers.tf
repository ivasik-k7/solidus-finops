# The provider's region and credentials come from the TFE workspace environment.
# Do NOT hardcode credentials here.
#
# Required TFE workspace environment variables:
#   AWS_ACCESS_KEY_ID         (or assumed-role via dynamic credentials)
#   AWS_SECRET_ACCESS_KEY     (or assumed-role via dynamic credentials)
#   AWS_SESSION_TOKEN         (if using temporary credentials)
#   AWS_DEFAULT_REGION        (or set var.aws_region)

provider "aws" {
  region = var.aws_region

  # Default tags applied to every resource the provider creates.
  # The framework's locals.tf computes the full tag set; we surface it here so
  # ad-hoc resources also pick them up.
  default_tags {
    tags = local.default_tags
  }
}

# A second provider alias is provided for the us-east-1 region.
# Certain services (CloudFront, ACM for CloudFront, Cost & Usage Reports v1 endpoints,
# Cost Anomaly Detection in some legacy contexts) require us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}
