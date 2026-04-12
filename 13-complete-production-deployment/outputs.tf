# ============================================================
# APPLICATION ACCESS
# ============================================================
output "app_url" {
  description = "Live application URL"
  value       = module.alb.app_url
}

output "health_check_url" {
  value = "https://${var.domain_name}/health"
}

output "alb_dns_name" {
  description = "ALB DNS (for debugging — use app_url for access)"
  value       = module.alb.alb_dns_name
}

# ============================================================
# SSH ACCESS
# ============================================================
output "bastion_public_ip" { value = module.bastion.public_ip }

output "ssh_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.bastion.public_ip}"
}

output "ssh_frontend_via_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.frontend.private_ip}"
}

output "ssh_backend_via_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.backend.private_ip}"
}

# ============================================================
# INFRASTRUCTURE DETAILS
# ============================================================
output "vpc_id" { value = module.vpc.vpc_id }
output "frontend_private_ip" { value = module.frontend.private_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }
output "db_name" { value = module.rds.db_name }

output "database_url_secret_name" {
  description = "Secrets Manager secret — retrieve with: aws secretsmanager get-secret-value --secret-id <name>"
  value       = module.secrets.database_url_secret_name
}

# ============================================================
# VERIFICATION COMMANDS
# ============================================================
output "verify_steps" {
  description = "Run these after apply to verify the deployment"
  value = {
    "1_health_check"  = "curl https://${var.domain_name}/health"
    "2_api_check"     = "curl https://${var.domain_name}/api/measurements"
    "3_open_browser"  = "https://${var.domain_name}"
    "4_check_secret"  = "aws secretsmanager get-secret-value --secret-id ${module.secrets.database_url_secret_name} --region ${var.aws_region} --query SecretString --output text"
    "5_backend_logs"  = "ssh -J ubuntu@${module.bastion.public_ip} ubuntu@${module.backend.private_ip} 'sudo tail -f /var/log/user-data.log'"
  }
}

output "destroy_reminder" {
  value = "After class: cd 13-complete-production-deployment && terraform destroy -auto-approve"
}
