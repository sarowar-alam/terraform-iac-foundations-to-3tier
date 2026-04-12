output "app_url" { value = module.alb.app_url }
output "bastion_public_ip" { value = module.bastion.public_ip }
output "db_endpoint" { value = module.rds.db_endpoint }
output "database_url_secret" { value = module.secrets.database_url_secret_name }
output "ssh_bastion" { value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.bastion.public_ip}" }
