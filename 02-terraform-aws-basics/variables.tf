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

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "key_name" {
  type    = string
  default = "sarowar-ostad-mumbai"
}

variable "allowed_ssh_cidr" {
  description = "Your IP address in CIDR notation: x.x.x.x/32"
  type        = string
}
