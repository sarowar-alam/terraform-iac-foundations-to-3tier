output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr" { value = module.vpc.vpc_cidr }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_app_subnet_ids" { value = module.vpc.private_app_subnet_ids }
output "private_db_subnet_ids" { value = module.vpc.private_db_subnet_ids }
output "internet_gateway_id" { value = module.vpc.internet_gateway_id }
output "nat_gateway_id" { value = module.vpc.nat_gateway_id }
output "nat_gateway_public_ip" { value = module.vpc.nat_gateway_public_ip }
