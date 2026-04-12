output "vpc_id" { value = module.vpc.vpc_id }
output "db_endpoint" { value = module.rds.db_endpoint }
output "db_host" { value = module.rds.db_host }
output "db_port" { value = module.rds.db_port }
output "db_name" { value = module.rds.db_name }
output "database_url_secret_name" { value = module.secrets.database_url_secret_name }

output "note" {
  value = "Database is in a PRIVATE subnet. Use bastion host or backend EC2 to connect."
}
