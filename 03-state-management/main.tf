# ==============================================================================
# 03 — State Management
# Demonstrates local state, remote S3 state with DynamoDB locking.
# Run bootstrap/ first to create the S3 bucket and DynamoDB table.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # STEP 2: Uncomment after running bootstrap/
  # Run: terraform init  (Terraform will ask to migrate local state to S3)
  # backend "s3" {
  #   bucket         = "terraform-state-bmi-ostaddevops"
  #   key            = "lessons/03-state-management/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "demo" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = var.key_name

  tags = {
    Name      = "state-management-demo"
    ManagedBy = "terraform"
  }
}
