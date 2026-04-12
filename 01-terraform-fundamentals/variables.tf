variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "key_name" {
  description = "Name of your EC2 key pair"
  type        = string
  default     = "sarowar-ostad-mumbai"
}

variable "project_name" {
  description = "Project name used in resource tags"
  type        = string
  default     = "bmi-health-tracker"
}

variable "subnet_id" {
  description = "ID of the public subnet to launch the instance into"
  type        = string
}
