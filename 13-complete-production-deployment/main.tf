# ==============================================================================
# 13 â€” Complete Production Deployment
#
# The FULL production architecture using ALL modules:
#   - VPC + 6 subnets + IGW + NAT GW
#   - Security Groups (all 5, Phase 2 rules)
#   - IAM Role + Instance Profile (Secrets Manager access)
#   - RDS PostgreSQL 14 (db.t3.medium, multi_az = true)
#   - AWS Secrets Manager (db-password + database-url)
#   - Bastion Host (public subnet)
#   - Backend EC2 (private app subnet, templatefile)
#   - Frontend EC2 (private app subnet, templatefile)
#   - ALB (public subnets, HTTPS:443, path routing)
#   - Route53 A alias record â†’ bmi.ostaddevops.click
#
# After class: terraform destroy  (deletion_protection = false)
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

  # Remote state â€” uncomment after running make bootstrap
  backend "s3" {
    bucket         = "terraform-state-bmi-ostaddevops"
    key            = "prod/13-complete-production-deployment/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
    profile        = "sarowar-ostad"
  }
}

provider "aws" {
  region = var.aws_region
  profile        = "sarowar-ostad"
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "devops"
    }
  }
}

# ==============================================================================
# NETWORKING
# ==============================================================================
module "vpc" {
  source = "./modules/vpc"
  project_name             = var.project_name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = var.availability_zones
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
}

# ==============================================================================
# SECURITY GROUPS
# ==============================================================================
module "security_groups" {
  source = "./modules/security-group"
  project_name           = var.project_name
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  frontend_public_access = false # Production: all traffic via ALB
}

# ==============================================================================
# IAM
# ==============================================================================
module "iam_backend" {
  source = "./modules/iam"
  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  role_suffix              = "backend"
  attach_ssm_policy        = true
  attach_cloudwatch_policy = true
}

module "iam_frontend" {
  source = "./modules/iam"
  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  role_suffix              = "frontend"
  attach_ssm_policy        = true
  attach_cloudwatch_policy = false
}

# ==============================================================================
# DATABASE PASSWORD
# Generated at root so both module.rds and module.secrets can receive it
# without creating a circular dependency.
# ==============================================================================
resource "random_password" "db_master" {
  length           = 16
  special          = true
  override_special = "!-_=+" # URL-safe only — avoids # $ > [ ] < : ? which break pg connection URLs
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# ==============================================================================
# DATABASE + SECRETS
# random_password lives at root — passed into both modules to break the cycle.
# ==============================================================================
module "rds" {
  source = "./modules/rds"

  project_name        = var.project_name
  environment         = var.environment
  subnet_ids          = module.vpc.private_db_subnet_ids
  security_group_id   = module.security_groups.rds_sg_id
  db_password         = random_password.db_master.result
  instance_class      = var.db_instance_class
  multi_az            = var.multi_az
  backup_retention_days = 1
  deletion_protection = false       # Allow clean terraform destroy after demo
  skip_final_snapshot = true
}

module "secrets" {
  source               = "./modules/secrets"
  project_name         = var.project_name
  environment          = var.environment
  db_password          = random_password.db_master.result
  db_host              = module.rds.db_host
  recovery_window_days = 0 # Immediate deletion — clean destroy after demo
}

# ==============================================================================
# COMPUTE â€” Bastion, Backend, Frontend
# ==============================================================================
module "backend" {
  source = "./modules/ec2"
  name                 = "${var.project_name}-${var.environment}-backend"
  role                 = "backend"
  instance_type        = var.backend_instance_type
  subnet_id            = module.vpc.private_app_subnet_ids[0]
  security_group_ids   = [module.security_groups.backend_sg_id]
  key_name             = null
  iam_instance_profile = module.iam_backend.instance_profile_name
  root_volume_size     = 20

  user_data = templatefile("${path.module}/scripts/backend.sh", {
    database_url_secret_name = module.secrets.database_url_secret_name
    frontend_url             = "https://${var.domain_name}"
    environment              = var.environment
    aws_region               = var.aws_region
  })

  depends_on = [module.secrets, module.rds]
}

module "frontend" {
  source = "./modules/ec2"
  name                 = "${var.project_name}-${var.environment}-frontend"
  role                 = "frontend"
  instance_type        = var.frontend_instance_type
  subnet_id            = module.vpc.private_app_subnet_ids[1]
  security_group_ids   = [module.security_groups.frontend_sg_id]
  key_name             = null
  root_volume_size     = 20
  iam_instance_profile = module.iam_frontend.instance_profile_name

  user_data = templatefile("${path.module}/scripts/frontend.sh", {
    backend_private_ip = module.backend.private_ip
    phase              = "production"
  })

  depends_on = [module.backend]
}

# ==============================================================================
# LOAD BALANCER + DNS
# ==============================================================================
module "alb" {
  source = "./modules/alb"
  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id

  public_subnet_ids     = module.vpc.public_subnet_ids
  alb_sg_id             = module.security_groups.alb_sg_id
  certificate_arn       = var.certificate_arn
  hosted_zone_id        = var.hosted_zone_id
  domain_name           = var.domain_name
  frontend_instance_ids = [module.frontend.instance_id]
  backend_instance_ids  = [module.backend.instance_id]
}
