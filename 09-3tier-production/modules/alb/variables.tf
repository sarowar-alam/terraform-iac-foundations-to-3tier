variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB (must span at least 2 AZs)"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security Group ID for the ALB"
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID for ostaddevops.click"
  type        = string
}

variable "domain_name" {
  description = "Full domain name for the application"
  type        = string
}

variable "frontend_instance_ids" {
  description = "List of frontend EC2 instance IDs to register in the frontend target group"
  type        = list(string)
}

variable "backend_instance_ids" {
  description = "List of backend EC2 instance IDs to register in the backend target group"
  type        = list(string)
}
