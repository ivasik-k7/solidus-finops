###############################################################################
# Provider + Terraform version requirements
#
# Pinned to the minimums this module actually needs. Caller can pin higher.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}
