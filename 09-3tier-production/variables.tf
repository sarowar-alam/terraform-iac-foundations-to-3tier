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

variable "key_name" {
  type    = string
  default = "sarowar-ostad-mumbai"
}

variable "allowed_ssh_cidr" {
  description = "Your IP: x.x.x.x/32"
  type        = string
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