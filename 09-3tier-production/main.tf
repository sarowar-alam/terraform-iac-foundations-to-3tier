# ==============================================================================
# 09 â€” 3-Tier Production Architecture (Module 7 Phase 2)
#
# Everything private. ALB is the ONLY internet-facing resource.
#
# Frontend EC2 â†’ PRIVATE app subnet (Nginx, port 80, SG: alb-sg only)
# Backend EC2  â†’ PRIVATE app subnet (Node.js PM2 port 3000, SG: alb-sg only)
# RDS          â†’ PRIVATE db subnet  (PostgreSQL 14)
# ALB          â†’ PUBLIC subnets     (HTTPS:443 with cert, HTTP:80 â†’ redirect)
# Route53      â†’ bmi.ostaddevops.click â†’ ALB DNS
#
# Traffic flow:
#   Internet â†’ Route53 â†’ ALB
#     /api/* â†’ Backend TG â†’ Backend EC2 :3000
#     /*     â†’ Frontend TG â†’ Frontend EC2 :80
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

# Phase 2: frontend_public_access = false â€” frontend SG allows 80 from alb-sg ONLY
module "security_groups" {
  source = "./modules/security-group"
  project_name           = var.project_name
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  frontend_public_access = false # KEY DIFFERENCE from Phase 1
}

module "iam_backend" {
  source = "./modules/iam"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  role_suffix  = "backend"
}

module "rds" {
  source = "./modules/rds"
  project_name        = var.project_name
  environment         = var.environment
  subnet_ids          = module.vpc.private_db_subnet_ids
  security_group_id   = module.security_groups.rds_sg_id
  db_password         = module.secrets.db_password
  instance_class      = var.db_instance_class
  multi_az            = false
  skip_final_snapshot = true
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

# Backend â€” PRIVATE subnet (same as Phase 1)
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
    frontend_url             = "https://${var.domain_name}"
    environment              = var.environment
    aws_region               = var.aws_region
  })

  depends_on = [module.secrets, module.rds]
}

# Frontend â€” PRIVATE subnet (KEY CHANGE from Phase 1)
module "frontend" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-frontend"
  role               = "frontend"
  instance_type      = var.frontend_instance_type
  subnet_id          = module.vpc.private_app_subnet_ids[1]
  security_group_ids = [module.security_groups.frontend_sg_id]
  key_name           = var.key_name

  user_data = templatefile("${path.module}/scripts/frontend.sh", {
    backend_private_ip = module.backend.private_ip
    phase              = "production"
  })

  depends_on = [module.backend]
}

# ALB â€” PUBLIC subnets, HTTPS with cert, path routing
module "alb" {
  source = "./modules/alb"
  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id

  public_subnet_ids    = module.vpc.public_subnet_ids
  alb_sg_id            = module.security_groups.alb_sg_id
  certificate_arn      = var.certificate_arn
  hosted_zone_id       = var.hosted_zone_id
  domain_name          = var.domain_name
  frontend_instance_ids = [module.frontend.instance_id]
  backend_instance_ids  = [module.backend.instance_id]
}
