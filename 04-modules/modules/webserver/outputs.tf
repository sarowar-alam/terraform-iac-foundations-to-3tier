output "instance_id" { value = aws_instance.web.id }
output "public_ip" { value = aws_instance.web.public_ip }
output "ssh_command" { value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${aws_instance.web.public_ip}" }
output "app_url" { value = "http://${aws_instance.web.public_ip}" }
