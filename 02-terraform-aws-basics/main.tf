# ==============================================================================
# 02 — Terraform AWS Basics
# EC2 + Security Group + Key Pair.
# Demonstrates: data sources, locals, multiple resources, outputs.
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
    tags = local.common_tags
  }
}

# ------------------------------------------------------------------------------
# Locals — computed values and shared tag map
# ------------------------------------------------------------------------------
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Fetch latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Fetch VPC by ID — set vpc_id in terraform.tfvars
data "aws_vpc" "named_vpc" {
  id = var.vpc_id
}

# Security Group — allow SSH and HTTP
resource "aws_security_group" "web" {
  name        = "${local.name_prefix}-basics-sg"
  description = "Allow SSH and HTTP"
  vpc_id      = data.aws_vpc.named_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-basics-sg"
  }
}

# EC2 Instance with a simple user_data script
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id          # ← add this line
  associate_public_ip_address = true
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    echo "<h1>Hello from Terraform!</h1><p>Instance: $(hostname)</p>" > /var/www/html/index.html
    systemctl enable nginx && systemctl start nginx
  EOF

  tags = {
    Name = "${local.name_prefix}-basics-ec2"
  }
}
