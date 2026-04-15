variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "bmi-health-tracker"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "frontend_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "backend_instance_type" {
  type    = string
  default = "t3.large"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "private_db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.5.0/24", "10.0.6.0/24"]
}

variable "certificate_arn" {
  type    = string
  default = "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0"
}

variable "hosted_zone_id" {
  type    = string
  default = "Z1019653XLWIJ02C53P5"
}

variable "domain_name" {
  type    = string
  default = "bmi.ostaddevops.click"
}