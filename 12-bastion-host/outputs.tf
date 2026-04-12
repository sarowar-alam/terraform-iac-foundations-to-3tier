output "bastion_public_ip" {
  value = module.bastion.public_ip
}

output "private_instance_ip" {
  value = module.private_instance.private_ip
}

output "ssh_to_bastion" {
  description = "Step 1: Connect to bastion"
  value       = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${module.bastion.public_ip}"
}

output "ssh_to_private_via_bastion" {
  description = "Step 2: ProxyJump through bastion to private instance (single command)"
  value       = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@${module.bastion.public_ip} ubuntu@${module.private_instance.private_ip}"
}

output "ssh_config_entry" {
  description = "Add to ~/.ssh/config for convenience"
  value       = <<-CONFIG
    # Add this to ~/.ssh/config
    Host bastion-bmi
      HostName ${module.bastion.public_ip}
      User ubuntu
      IdentityFile ~/sarowar-ostad-mumbai.pem

    Host backend-bmi
      HostName ${module.private_instance.private_ip}
      User ubuntu
      IdentityFile ~/sarowar-ostad-mumbai.pem
      ProxyJump bastion-bmi

    # Then simply use: ssh backend-bmi
  CONFIG
}
