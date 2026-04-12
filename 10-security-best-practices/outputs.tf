output "bastion_public_ip" { value = module.bastion.public_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }
output "iam_role_arn" { value = module.iam_backend.role_arn }
output "database_url_secret_name" { value = module.secrets.database_url_secret_name }

output "security_summary" {
  value = {
    rds_publicly_accessible = false
    rds_encrypted           = true
    ssh_restricted_to       = var.allowed_ssh_cidr
    backend_port            = "3000 — accessible from alb-sg only"
    db_port                 = "5432 — accessible from backend-sg only"
    secrets_manager_secret  = module.secrets.database_url_secret_name
  }
}
