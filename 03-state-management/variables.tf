variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "key_name" {
  type    = string
  default = "sarowar-ostad-mumbai"
}

variable "subnet_id" {
  description = "ID of the public subnet to launch the instance into"
  type        = string
}
