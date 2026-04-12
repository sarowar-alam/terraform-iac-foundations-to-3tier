# ==============================================================================
# Remote State Backend — S3 + DynamoDB
#
# HOW TO USE:
# 1. First run: cd 03-state-management/bootstrap && terraform apply
#    This creates the S3 bucket and DynamoDB table.
#
# 2. Copy this backend block into your module's main.tf or backend.tf
#    and uncomment it.
#
# 3. Run: terraform init  (Terraform will migrate local state to S3)
# ==============================================================================

# terraform {
#   backend "s3" {
#     bucket         = "terraform-state-bmi-ostaddevops"
#     key            = "<environment>/terraform.tfstate"   # e.g. "prod/terraform.tfstate"
#     region         = "ap-south-1"
#     dynamodb_table = "terraform-state-lock"
#     encrypt        = true
#   }
# }

# ------------------------------------------------------------------------------
# State bucket naming convention:
#   terraform-state-bmi-ostaddevops
#
# State key convention (per environment):
#   dev/terraform.tfstate
#   staging/terraform.tfstate
#   prod/terraform.tfstate
#
# Per lesson module (when learning state isolation):
#   lessons/01-fundamentals/terraform.tfstate
#   lessons/03-state-management/terraform.tfstate
# ------------------------------------------------------------------------------
