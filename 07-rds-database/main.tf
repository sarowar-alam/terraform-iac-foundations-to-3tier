# ==============================================================================
# 07 â€” RDS Database
# Extracts the database out of the single EC2 into a managed RDS instance.
# First architectural split: local PostgreSQL â†’ AWS RDS (private subnet).
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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

module "security_groups" {
  source = "./modules/security-group"
  project_name     = var.project_name
  environment      = var.environment
  vpc_id           = module.vpc.vpc_id
  allowed_ssh_cidr = var.allowed_ssh_cidr
}

# Database credentials via Secrets Manager
module "secrets" {
  source = "./modules/secrets"
  project_name = var.project_name
  environment  = var.environment
  db_host      = module.rds.db_host
  depends_on   = [module.rds]
}

module "rds" {
  source = "./modules/rds"
  project_name = var.project_name
  environment  = var.environment
  subnet_ids   = module.vpc.private_db_subnet_ids
  security_group_id    = module.security_groups.rds_sg_id
  db_password          = module.secrets.db_password
  instance_class       = var.db_instance_class
  multi_az             = false
  skip_final_snapshot  = true
}
