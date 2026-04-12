# ==============================================================================
# 08 â€” 3-Tier Architecture: Basic (Module 7 Phase 1)
#
# Frontend EC2  â†’ PUBLIC subnet  (Nginx, port 80 open to internet)
# Backend EC2   â†’ PRIVATE app subnet (Node.js PM2 port 3000)
# RDS           â†’ PRIVATE db subnet  (PostgreSQL 14)
#
# Traffic flow:
#   Internet â†’ Frontend EC2 (public IP:80) â†’ Backend private IP:3000 â†’ RDS
#
# Bastion â†’ jump SSH to frontend and backend
# NAT GW  â†’ private subnets get outbound internet (for apt/npm/git)
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

# VPC + all subnets
module "vpc" {
  source = "./modules/vpc"
  project_name = var.project_name
  environment  = var.environment
}

# Phase 1: frontend_public_access = true â€” frontend SG allows 80 from internet
module "security_groups" {
  source = "./modules/security-group"
  project_name           = var.project_name
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  frontend_public_access = true # Phase 1 setting
}

# IAM role for backend â†’ Secrets Manager
module "iam_backend" {
  source = "./modules/iam"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  role_suffix  = "backend"
}

# RDS PostgreSQL
module "rds" {
  source = "./modules/rds"
  project_name      = var.project_name
  environment       = var.environment
  subnet_ids        = module.vpc.private_db_subnet_ids
  security_group_id = module.security_groups.rds_sg_id
  db_password       = module.secrets.db_password
  instance_class    = var.db_instance_class
  multi_az          = false
  skip_final_snapshot = true
}

# Secrets Manager â€” create after RDS so db_host is available
module "secrets" {
  source = "./modules/secrets"
  project_name = var.project_name
  environment  = var.environment
  db_host      = module.rds.db_host
  depends_on   = [module.rds]
}

# Bastion host â€” SSH jump server in public subnet
module "bastion" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-bastion"
  role               = "bastion"
  instance_type      = "t3.micro"
  subnet_id          = module.vpc.public_subnet_ids[0]
  security_group_ids = [module.security_groups.bastion_sg_id]
  key_name           = var.key_name
}

# Backend EC2 â€” PRIVATE app subnet
module "backend" {
  source = "./modules/ec2"
  name                 = "${var.project_name}-${var.environment}-backend"
  role                 = "backend"
  instance_type        = var.backend_instance_type
  subnet_id            = module.vpc.private_app_subnet_ids[0]
  security_group_ids   = [module.security_groups.backend_sg_id]
  key_name             = var.key_name
  iam_instance_profile = module.iam_backend.instance_profile_name

  user_data = templatefile("${path.module}/scripts/backend.sh", {
    database_url_secret_name = module.secrets.database_url_secret_name
    frontend_url             = "http://${module.frontend.public_ip}"
    environment              = var.environment
    aws_region               = var.aws_region
  })

  depends_on = [module.secrets, module.rds]
}

# Frontend EC2 â€” PUBLIC subnet (Phase 1: directly internet-accessible)
module "frontend" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-frontend"
  role               = "frontend"
  instance_type      = var.frontend_instance_type
  subnet_id          = module.vpc.public_subnet_ids[0]
  security_group_ids = [module.security_groups.frontend_sg_id]
  key_name           = var.key_name

  user_data = templatefile("${path.module}/scripts/frontend.sh", {
    backend_private_ip = module.backend.private_ip
    phase              = "basic"
  })

  depends_on = [module.backend]
}
