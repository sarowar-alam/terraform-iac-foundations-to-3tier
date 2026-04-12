output "bastion_public_ip" { value = module.bastion.public_ip }
output "frontend_private_ip" { value = module.frontend.private_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }

output "monitor_backend_boot" {
  value = "ssh -J ubuntu@${module.bastion.public_ip} ubuntu@${module.backend.private_ip} 'sudo tail -f /var/log/user-data.log'"
}

output "monitor_frontend_boot" {
  value = "ssh -J ubuntu@${module.bastion.public_ip} ubuntu@${module.frontend.private_ip} 'sudo tail -f /var/log/user-data.log'"
}

output "template_vars_sent_to_backend" {
  description = "These values were injected into backend.sh via templatefile()"
  value = {
    database_url_secret_name = module.secrets.database_url_secret_name
    frontend_url             = "https://${var.domain_name}"
    environment              = var.environment
    aws_region               = var.aws_region
  }
}
