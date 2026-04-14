# ==============================================================================
# Bootstrap: Creates S3 bucket + DynamoDB table for Terraform remote state.
# Run ONCE before enabling the S3 backend in 03-state-management/main.tf
#
# Usage:
#   cd 03-state-management/bootstrap
#   terraform init && terraform apply
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Bootstrap state is local — do NOT use remote state for bootstrap itself
}

provider "aws" {
  region = "ap-south-1"
  profile = "sarowar-ostad"  # Using your AWS profile

}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "terraform-state-bmi-ostaddevops"

  # # Prevent accidental deletion of the state bucket
  # lifecycle {
  #   prevent_destroy = true
  # }

  tags = {
    Name      = "terraform-state-bmi-ostaddevops"
    ManagedBy = "terraform"
    Purpose   = "Terraform remote state storage"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled" # Versioning enables state history and rollback
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — state files must never be public
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name      = "terraform-state-lock"
    ManagedBy = "terraform"
    Purpose   = "Terraform state locking"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.terraform_lock.name
}

output "next_step" {
  value = "Go back to 03-state-management/, uncomment the backend block in main.tf, then run: terraform init"
}
