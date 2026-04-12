output "instance_id" { value = module.single_instance.instance_id }
output "public_ip" { value = module.single_instance.public_ip }

output "app_url" {
  description = "BMI App URL — wait ~3 mins for user_data to complete"
  value       = "http://${module.single_instance.public_ip}"
}

output "health_check_url" {
  value = "http://${module.single_instance.public_ip}/health"
}

output "ssh_command" {
  value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.single_instance.public_ip}"
}

output "check_logs" {
  description = "SSH in and run this to watch installation progress"
  value       = "sudo tail -f /var/log/user-data.log"
}
