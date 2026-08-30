# backend.tf
#
# Tells Terraform to store its state file remotely in S3 instead of
# locally on disk. This makes state visible/shared across every
# Jenkins job and every machine, and prevents it from being lost
# when a Jenkins workspace is cleaned up.

terraform {
  backend "s3" {
    bucket         = "yaathvik-terraform-state-2026"
    key            = "practice-branch/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
