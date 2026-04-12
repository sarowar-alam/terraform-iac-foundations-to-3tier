# ==============================================================================
# 11 â€” User Data Automation
# Deep dive into EC2 user_data bootstrapping using Terraform's templatefile().
#
# Shows:
#   - templatefile() function: inject Terraform values into shell scripts
#   - Template variables passed to scripts/backend.sh and scripts/frontend.sh
#   - How to monitor user_data execution: tail /var/log/user-data.log
#   - cloud-init patterns for production bootstrapping
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
  project_name           = var.project_name
  environment            = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr       = var.allowed_ssh_cidr
  frontend_public_access = false
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

# Backend â€” templatefile() injects secret name, frontend URL, environment into script
module "backend" {
  source = "./modules/ec2"
  name                 = "${var.project_name}-${var.environment}-backend"
  role                 = "backend"
  instance_type        = "t3.small"
  subnet_id            = module.vpc.private_app_subnet_ids[0]
  security_group_ids   = [module.security_groups.backend_sg_id]
  key_name             = var.key_name
  iam_instance_profile = module.iam_backend.instance_profile_name

  # templatefile() renders backend.sh with actual values â€” no secrets in code
  user_data = templatefile("${path.module}/scripts/backend.sh", {
    database_url_secret_name = module.secrets.database_url_secret_name
    frontend_url             = "https://${var.domain_name}"
    environment              = var.environment
    aws_region               = var.aws_region
  })

  depends_on = [module.secrets, module.rds]
}

# Frontend â€” templatefile() injects backend IP and phase
module "frontend" {
  source = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-frontend"
  role               = "frontend"
  instance_type      = "t3.micro"
  subnet_id          = module.vpc.private_app_subnet_ids[1]
  security_group_ids = [module.security_groups.frontend_sg_id]
  key_name           = var.key_name

  user_data = templatefile("${path.module}/scripts/frontend.sh", {
    backend_private_ip = module.backend.private_ip
    phase              = "production"
  })

  depends_on = [module.backend]
}
