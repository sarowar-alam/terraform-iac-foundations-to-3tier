# ==============================================================================
# 01 — Terraform Fundamentals
# First EC2 instance using Terraform.
# Demonstrates: init, plan, apply, destroy workflow.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data source: always fetch the latest Ubuntu 22.04 AMI (never hardcode)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# First EC2 instance
resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  tags = {
    Name        = "${var.project_name}-first-instance"
    Environment = "learning"
    ManagedBy   = "terraform"
  }
}
