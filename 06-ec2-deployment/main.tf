# ==============================================================================
# 06 â€” EC2 Deployment (Module 4 â€” All 3 Tiers on Single Instance)
#
# This is the Terraform equivalent of what was done manually in Module 4.
# One EC2 instance runs PostgreSQL + Node.js backend + Nginx frontend.
#
# "In Module 4 you ran 40+ commands by hand. Here's the same result
# in a single terraform apply."
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
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Security Group â€" same ports as Module 4 manual setup
resource "aws_security_group" "single_instance" {
  name        = "${var.project_name}-${var.environment}-single-sg"
  description = "Module 4: SSH, HTTP, HTTPS, backend API"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTP (Nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-single-sg" }
}

# Single EC2 instance â€” all three tiers
module "single_instance" {
  source = "./modules/ec2"

  name               = "${var.project_name}-${var.environment}-single-instance"
  role               = "all-tiers"
  instance_type      = var.instance_type
  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.single_instance.id]
  key_name           = var.key_name
  root_volume_size   = 30 # extra space for PostgreSQL + Node + React build

  # Inject the full setup script as user_data
  user_data = file("${path.module}/scripts/single-instance.sh")
}


