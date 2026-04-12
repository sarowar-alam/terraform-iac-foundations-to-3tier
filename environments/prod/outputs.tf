output "app_url" { value = module.alb.app_url }
output "alb_dns_name" { value = module.alb.alb_dns_name }
output "bastion_public_ip" { value = module.bastion.public_ip }
output "frontend_private_ip" { value = module.frontend.private_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }
output "database_url_secret" { value = module.secrets.database_url_secret_name }

output "ssh_bastion" {
  value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.bastion.public_ip}"
}
output "ssh_backend" {
  value = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.backend.private_ip}"
}
output "ssh_frontend" {
  value = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.frontend.private_ip}"
}
output "verify" {
  value = "curl https://${var.domain_name}/health"
}
