# ==============================================================================
# 12 â€” Bastion Host
# Secure SSH access pattern for private resources.
#
# Covers:
#   - Bastion EC2 in public subnet, Port 22 from your IP only
#   - SSH ProxyJump (-J flag) to reach private EC2s
#   - ~/.ssh/config entry for convenience
#   - Why NOT to use 0.0.0.0/0 for SSH
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

module "vpc" {
  source = "./modules/vpc"
  project_name = var.project_name
  environment  = var.environment
}

# Bastion Security Group â€” SSH ONLY from your IP
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-${var.environment}-bastion-demo-sg"
  description = "Bastion: SSH from ${var.allowed_ssh_cidr} only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH from your IP only â€” never 0.0.0.0/0"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-bastion-sg" }
}

# Private instance SG â€” SSH only from bastion
resource "aws_security_group" "private_instance" {
  name        = "${var.project_name}-${var.environment}-private-sg"
  description = "Private EC2: SSH from bastion only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-private-sg" }
}

module "bastion" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-bastion"
  role               = "bastion"
  instance_type      = "t3.micro"
  subnet_id          = module.vpc.public_subnet_ids[0]
  security_group_ids = [aws_security_group.bastion.id]
  key_name           = var.key_name
}

# Demo private instance (represents backend or frontend in private subnet)
module "private_instance" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-private-demo"
  role               = "backend"
  instance_type      = "t3.micro"
  subnet_id          = module.vpc.private_app_subnet_ids[0]
  security_group_ids = [aws_security_group.private_instance.id]
  key_name           = var.key_name
}
