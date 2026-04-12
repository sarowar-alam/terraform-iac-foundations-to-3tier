output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "Public IP address"
  value       = aws_instance.web.public_ip
}

output "public_dns" {
  description = "Public DNS name"
  value       = aws_instance.web.public_dns
}

output "ami_used" {
  description = "AMI ID that was automatically selected (Ubuntu 22.04 LTS)"
  value       = data.aws_ami.ubuntu.id
}
