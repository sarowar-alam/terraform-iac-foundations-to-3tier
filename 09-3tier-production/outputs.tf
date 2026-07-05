output "app_url" { value = module.alb.app_url }
output "alb_dns_name" { value = module.alb.alb_dns_name }
output "frontend_private_ip" { value = module.frontend.private_ip }
output "backend_private_ip" { value = module.backend.private_ip }
output "db_endpoint" { value = module.rds.db_endpoint }
output "database_url_secret" { value = module.secrets.database_url_secret_name }

output "ssm_connect_frontend" {
  value = "aws ssm start-session --target ${module.frontend.instance_id} --region ${var.aws_region}"
}
output "ssm_connect_backend" {
  value = "aws ssm start-session --target ${module.backend.instance_id} --region ${var.aws_region}"
}

output "verify_commands" {
  value = {
    health_check    = "curl https://${var.domain_name}/health"
    api_check       = "curl https://${var.domain_name}/api/measurements"
    open_in_browser = "https://${var.domain_name}"
  }
}
