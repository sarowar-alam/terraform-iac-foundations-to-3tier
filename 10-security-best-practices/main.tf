# ==============================================================================
# 10 â€” Security Best Practices
# Demonstrates security layers across all tiers.
#
# Key concepts covered:
#   - Security groups with least-privilege rules
#   - IAM roles with minimal permissions (no wildcard *)
#   - RDS encryption at rest
#   - AWS Secrets Manager (zero passwords in code)
#   - No public access on RDS (publicly_accessible = false)
#   - SSH restricted to bastion only
#   - SSM Session Manager as SSH alternative (no port 22 required)
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

# Security groups demonstrate explicit least-privilege rules
module "security_groups" {
  source = "./modules/security-group"
  project_name           = var.project_name
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  frontend_public_access = false
}

# IAM â€” backend role allows only GetSecretValue on project secrets
module "iam_backend" {
  source = "./modules/iam"
  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  role_suffix              = "backend"
  attach_ssm_policy        = true  # SSM Session Manager: access without port 22
  attach_cloudwatch_policy = true  # Ship logs to CloudWatch
}

module "rds" {
  source = "./modules/rds"
  project_name        = var.project_name
  environment         = var.environment
  subnet_ids          = module.vpc.private_db_subnet_ids
  security_group_id   = module.security_groups.rds_sg_id
  db_password         = module.secrets.db_password
  instance_class      = "db.t3.micro"
  multi_az            = false
  skip_final_snapshot = true
  # storage_encrypted = true is set by default in the rds module
  # publicly_accessible = false is set by default in the rds module
}

module "secrets" {
  source = "./modules/secrets"
  project_name = var.project_name
  environment  = var.environment
  db_host      = module.rds.db_host
  depends_on   = [module.rds]
}

module "bastion" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-bastion"
  role               = "bastion"
  instance_type      = "t3.micro"
  subnet_id          = module.vpc.public_subnet_ids[0]
  security_group_ids = [module.security_groups.bastion_sg_id]
  key_name           = var.key_name
}

# Demonstrate security-hardened backend instance
module "backend" {
  source = "./modules/ec2"
  name                 = "${var.project_name}-${var.environment}-backend"
  role                 = "backend"
  instance_type        = "t3.small"
  subnet_id            = module.vpc.private_app_subnet_ids[0]
  security_group_ids   = [module.security_groups.backend_sg_id]
  key_name             = var.key_name
  iam_instance_profile = module.iam_backend.instance_profile_name # IAM role attached

  user_data = templatefile("${path.module}/scripts/backend.sh", {
    database_url_secret_name = module.secrets.database_url_secret_name
    frontend_url             = "https://${var.domain_name}"
    environment              = var.environment
    aws_region               = var.aws_region
  })

  depends_on = [module.secrets, module.rds]
}
