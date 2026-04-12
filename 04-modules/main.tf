# ==============================================================================
# 04 — Terraform Modules
# Shows how to create and call a reusable local module.
# The webserver module packages EC2 + SG into a reusable component.
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

# Call the local webserver module
module "web_server" {
  source = "./modules/webserver"

  # Pass variables into the module
  project_name     = var.project_name
  environment      = var.environment
  vpc_id           = var.vpc_id
  subnet_id        = var.subnet_id
  instance_type    = var.instance_type
  key_name         = var.key_name
  allowed_ssh_cidr = var.allowed_ssh_cidr
}
