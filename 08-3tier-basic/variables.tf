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
  description = "Your IP: x.x.x.x/32"
  type        = string
}

variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "backend_instance_type" {
  type    = string
  default = "t3.small"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}