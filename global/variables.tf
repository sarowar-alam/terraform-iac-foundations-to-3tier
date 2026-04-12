# ==============================================================================
# Global Variables — shared across all modules and environments
# ==============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "bmi-health-tracker"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "key_name" {
  description = "Name of the existing EC2 key pair in ap-south-1"
  type        = string
  default     = "sarowar-ostad-mumbai"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the bastion host. Restrict to your IP."
  type        = string
  # No default — must be explicitly provided. Use: curl ifconfig.me to get your IP.
  # Example: "203.0.113.10/32"
}
