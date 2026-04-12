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
  default = "dev"
}

variable "key_name" {
  type    = string
  default = "sarowar-ostad-mumbai"
}

variable "allowed_ssh_cidr" {
  description = "Your IP: x.x.x.x/32 — get it with: curl ifconfig.me"
  type        = string
}