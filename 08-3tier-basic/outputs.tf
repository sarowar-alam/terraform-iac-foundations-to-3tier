output "vpc_id" { value = module.vpc.vpc_id }

output "bastion_public_ip" { value = module.bastion.public_ip }
output "frontend_public_ip" { value = module.frontend.public_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }

output "app_url" {
  description = "BMI App — Phase 1 (frontend direct, no ALB)"
  value       = "http://${module.frontend.public_ip}"
}

output "health_check" {
  value = "http://${module.frontend.public_ip}/health"
}

output "ssh_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.bastion.public_ip}"
}

output "ssh_backend_via_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.backend.private_ip}"
}

output "database_url_secret" {
  value = module.secrets.database_url_secret_name
}
