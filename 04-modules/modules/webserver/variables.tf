variable "project_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" {
  description = "ID of the public subnet to launch the instance into"
  type        = string
}
variable "instance_type" {
  type    = string
  default = "t2.micro"
}
variable "key_name" {
  type    = string
  default = "sarowar-ostad-mumbai"
}
variable "allowed_ssh_cidr" { type = string }
