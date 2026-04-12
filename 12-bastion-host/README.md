# 12 — Bastion Host

> **Module 8: Secure SSH Access with ProxyJump**
> Deploy a hardened bastion host (jump server) to SSH into private EC2 instances. Never expose port 22 to `0.0.0.0/0`.

---

## What You Will Learn

- What a bastion host is and why it's a security requirement
- SSH ProxyJump (`-J` flag): reach private instances through the bastion
- `~/.ssh/config`: configure ProxyJump permanently (no `-J` needed every time)
- Security Group design: bastion open port 22 to **your IP only**, private instances open port 22 to **bastion SG only**
- Why you should NEVER allow `0.0.0.0/0` on SSH
- Bastion host hardening: minimal attack surface (t3.micro, Ubuntu, no app installed)

---

## Architecture

```
Your Laptop
    │
    ▼ SSH Port 22 (from YOUR_IP/32 only)
Bastion EC2  [Public Subnet 10.0.1.0/24]
    │
    ▼ SSH Port 22 (from bastion-sg only)
Private EC2  [Private-App Subnet 10.0.3.0/24]
    │  (represents backend or frontend in a real deployment)
    │
    ▼ (no internet path)
RDS PostgreSQL  [Private-DB Subnet]  ← reachable from private EC2
```

---

## Folder Structure

```
12-bastion-host/
├── main.tf                  ← bastion SG (inline), private SG (inline), VPC module, 2 EC2s
├── variables.tf             ← allowed_ssh_cidr, key_name
├── outputs.tf               ← bastion_public_ip, private_instance_ip, ssh_config_entry
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
└── modules/
    ├── vpc/                 ← VPC with public and private subnets
    └── ec2/                 ← Generic EC2 module (used for bastion + private instance)
```

---

## Prerequisites

- [05-networking-vpc](../05-networking-vpc/README.md) completed (understand VPC layout)
- Key pair `sarowar-ostad-mumbai` exists in ap-south-1

---

## Step-by-Step Deployment

### Step 1: Get Your Public IP

```bash
curl ifconfig.me
# Example: 203.x.x.x
```

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region       = "ap-south-1"
project_name     = "bmi-health-tracker"
environment      = "dev"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "203.x.x.x/32"   # YOUR exact IP from curl ifconfig.me
```

### Step 3: Deploy

```bash
terraform init
terraform plan
terraform apply
```

### Step 4: Get SSH Details

```bash
terraform output
# bastion_public_ip     = "13.x.x.x"
# private_instance_ip   = "10.0.3.x"
# ssh_config_entry      = (see below)
```

### Step 5: SSH to Bastion

```bash
BASTION=$(terraform output -raw bastion_public_ip)

ssh -i sarowar-ostad-mumbai.pem ubuntu@$BASTION

# If connection refused: wait 1-2 min for EC2 to pass status checks
# If timeout: your IP may have changed — update allowed_ssh_cidr
```

### Step 6: SSH to Private Instance via ProxyJump

**Method A — Command line flag:**
```bash
BASTION=$(terraform output -raw bastion_public_ip)
PRIVATE=$(terraform output -raw private_instance_ip)

ssh -i sarowar-ostad-mumbai.pem \
    -J ubuntu@$BASTION \
    ubuntu@$PRIVATE
```

**Method B — `~/.ssh/config` (recommended):**
```bash
# Get the config entry
terraform output ssh_config_entry
```

Add the output to `~/.ssh/config`:
```
Host bmi-bastion
  HostName 13.x.x.x
  User ubuntu
  IdentityFile ~/sarowar-ostad-mumbai.pem

Host bmi-private
  HostName 10.0.3.x
  User ubuntu
  IdentityFile ~/sarowar-ostad-mumbai.pem
  ProxyJump bmi-bastion
```

Now connect directly:
```bash
ssh bmi-private   # automatically jumps through bastion
```

### Step 7: Verify the Security Model

```bash
# Test: Try to SSH to private instance DIRECTLY (should fail)
PRIVATE=$(terraform output -raw private_instance_ip)
ssh -i sarowar-ostad-mumbai.pem ubuntu@$PRIVATE
# Expected: Connection timed out (no public IP, no public route)

# Test: Try to SSH to bastion from a different IP (should fail)
# (Use your phone's hotspot to simulate a different IP)
ssh -i sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw bastion_public_ip)
# Expected: Connection timed out (your phone IP is not in allowed_ssh_cidr)
```

### Step 8: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### Why a Bastion Host?

Private EC2 instances (backend, frontend in Phase 2) have **no public IP**. To SSH in you need a proxy. The bastion is the **only** instance with a public IP and port 22 open.

```
Without bastion:
  Your laptop → private EC2  ✗  (private IP, no route from internet)

With bastion (ProxyJump):
  Your laptop → bastion → private EC2  ✓
```

### Security Group Chain

```
your_ip/32 → bastion-sg (port 22) → bastion EC2
                                          │
                bastion-sg → private-sg (port 22) → private EC2
```

The private EC2's SG references the **bastion security group by ID** — not an IP range. This means even if the bastion's public IP changes (EC2 stop/start), the SG rule still works.

```hcl
# BAD — IP-based (breaks if bastion IP changes)
ingress {
  from_port   = 22
  cidr_blocks = ["13.x.x.x/32"]
}

# GOOD — SG reference (always up to date)
ingress {
  from_port       = 22
  security_groups = [aws_security_group.bastion.id]
}
```

### ProxyJump Explained

SSH ProxyJump (`-J`) works by:
1. Opening an SSH connection to the bastion
2. Asking the bastion to forward a TCP connection to the private instance's IP
3. Opening a second SSH connection through that tunnel directly from your laptop to the private instance

Your private key **never** leaves your laptop. The bastion cannot see your SSH session.

### Alternative: AWS SSM Session Manager

If you can't open port 22 at all, use SSM Session Manager (see [10-security-best-practices](../10-security-best-practices/README.md)):
```bash
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx
```
No bastion, no port 22, no key pair needed.

---

## Verify

```bash
# Confirm bastion SG allows only your IP on port 22
aws ec2 describe-security-groups \
  --group-ids $(terraform output -raw bastion_sg_id) \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges" \
  --output table
# Should show YOUR_IP/32 only — NOT 0.0.0.0/0

# Confirm private SG references bastion SG (not an IP)
aws ec2 describe-security-groups \
  --group-ids $(terraform output -raw private_sg_id) \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].UserIdGroupPairs[0].GroupId" \
  --output text
# Should show bastion's SG ID
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Next Step

→ **[13-complete-production-deployment](../13-complete-production-deployment/README.md)** — tie everything together into a full production deployment.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
