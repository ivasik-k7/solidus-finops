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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }

  # No backend block — Terraform Enterprise manages state.
  # If running locally for development, uncomment a backend block here.
}
