# 08 — 3-Tier Architecture: Basic (Module 7 Phase 1)

> **Module 7 Phase 1: Public Frontend, Private Backend + DB**
> Deploy the BMI Health Tracker across three tiers. Frontend is publicly accessible on port 80; backend and database are in private subnets.

---

## What You Will Learn

- The 3-tier architecture pattern (Presentation → Application → Data)
- VPC with public and private subnets working together
- Bastion host for SSH access to private EC2s
- IAM instance profile: letting EC2 fetch secrets from AWS Secrets Manager
- `templatefile()`: inject Terraform values into shell scripts at deploy time
- PM2 process manager keeping Node.js alive
- Nginx as a reverse proxy in Phase 1 (direct requests to backend)
- Phase 1 vs Phase 2 security group difference

---

## Architecture

```
Internet
    │
    ▼ Port 80 / 443 (direct)
Frontend EC2  [Public Subnet 10.0.1.0/24]
    │  Nginx: / → React app, /api/* → proxy to backend:3000
    │
    ▼ Port 3000 (VPC internal only)
Backend EC2   [Private-App Subnet 10.0.3.0/24]
    │  Node.js + PM2: fetches DATABASE_URL from Secrets Manager on boot
    │
    ▼ Port 5432 (VPC internal only)
RDS PostgreSQL [Private-DB Subnet 10.0.5.0/24]

Bastion EC2   [Public Subnet 10.0.1.0/24]
    └── SSH jump → Frontend (SSH → bastion → frontend)
    └── SSH jump → Backend  (SSH → bastion → backend)

NAT Gateway   [Public Subnet 10.0.1.0/24]
    └── Gives private subnets outbound internet (apt, npm, git)
```

---

## Key Difference from Phase 2

| | Phase 1 (this folder) | Phase 2 (09-3tier-production) |
|-|-----------------------|-------------------------------|
| `frontend_public_access` | `true` | `false` |
| Frontend SG port 80 | Open to `0.0.0.0/0` | ALB security group only |
| ALB | None | Required |
| HTTPS | No | Yes (ACM certificate) |
| Domain | IP address | `bmi.ostaddevops.click` |

---

## Folder Structure

```
08-3tier-basic/
├── main.tf                  ← all modules wired together, frontend_public_access=true
├── variables.tf             ← Frontend/backend instance types, DB class, SSH CIDR
├── outputs.tf               ← app_url, backend_private_ip, ssh commands
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
├── modules/
│   ├── vpc/                 ← VPC with 6 subnets, IGW, NAT GW
│   ├── security-group/      ← 5 SGs with frontend_public_access flag
│   ├── iam/                 ← EC2 role for Secrets Manager access
│   ├── rds/                 ← PostgreSQL 14 in private-db subnet
│   ├── secrets/             ← Secrets Manager: db-password + database-url
│   └── ec2/                 ← Generic EC2 module (used 3 times)
└── scripts/
    ├── backend.sh           ← Node.js + PM2 bootstrap, fetches DB secret
    └── frontend.sh          ← Nginx + React build bootstrap (phase=basic)
```

---

## Prerequisites

- [07-rds-database](../07-rds-database/README.md) completed (understand RDS + Secrets Manager)
- Key pair `sarowar-ostad-mumbai` exists in ap-south-1

---

## Step-by-Step Deployment

### Step 1: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region              = "ap-south-1"
project_name            = "bmi-health-tracker"
environment             = "basic"
key_name                = "sarowar-ostad-mumbai"
allowed_ssh_cidr        = "YOUR_IP/32"   # curl ifconfig.me
frontend_instance_type  = "t3.small"
backend_instance_type   = "t3.small"
db_instance_class       = "db.t3.micro"
```

### Step 2: Deploy

```bash
terraform init
terraform plan
terraform apply
```

This creates ~35 resources. **Wait 8-10 minutes** for RDS and EC2 user_data scripts to complete.

### Step 3: Wait for Application Startup

EC2 user_data scripts run in the background. Monitor progress:

```bash
# Get bastion IP
BASTION=$(terraform output -raw bastion_public_ip)

# SSH to bastion
ssh -i sarowar-ostad-mumbai.pem ubuntu@$BASTION

# From bastion — SSH to frontend
FRONTEND=$(terraform output -raw frontend_public_ip)
ssh -i sarowar-ostad-mumbai.pem -J ubuntu@$BASTION ubuntu@$FRONTEND

# Watch user_data log on frontend
sudo tail -f /var/log/user-data.log
```

### Step 4: Test the Application

```bash
# Get app URL
terraform output app_url
# Example: http://13.x.x.x

# Test frontend (React app)
curl http://$(terraform output -raw frontend_public_ip)

# Test backend API via frontend proxy
curl http://$(terraform output -raw frontend_public_ip)/api/health
# Expected: {"status":"ok","environment":"basic"}

# Test direct backend (should FAIL from internet — private subnet)
curl http://$(terraform output -raw backend_private_ip):3000/health
# Expected: no response (private, not reachable from internet)
```

### Step 5: SSH via Bastion (ProxyJump)

```bash
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)

# Jump through bastion to backend EC2
ssh -i sarowar-ostad-mumbai.pem \
    -J ubuntu@$BASTION \
    ubuntu@$BACKEND

# Check PM2 on backend
pm2 status
pm2 logs
```

### Step 6: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### `frontend_public_access = true` (Phase 1)

```hcl
module "security_groups" {
  source                 = "./modules/security-group"
  frontend_public_access = true   # ← Phase 1 setting
}
```

When `true`, the security group module adds an ingress rule:
```
Frontend SG: allow port 80 from 0.0.0.0/0
```

In Phase 2, this is changed to `false` and only the ALB security group can reach port 80.

### IAM Instance Profile
The backend EC2 needs to read from Secrets Manager. Instead of hardcoding AWS credentials (NEVER do this), we attach an IAM role:

```hcl
module "iam_backend" {
  source = "./modules/iam"
  # Creates ec2-role → allows GetSecretValue on /basic/bmi-health-tracker/* only
}

module "backend" {
  source               = "./modules/ec2"
  iam_instance_profile = module.iam_backend.instance_profile_name
}
```

Inside the backend EC2, the script runs:
```bash
aws secretsmanager get-secret-value \
  --secret-id "/basic/bmi-health-tracker/database-url" \
  --query SecretString --output text
```
No AWS credentials needed — the instance role provides access automatically.

### `templatefile()`

```hcl
user_data = templatefile("${path.module}/scripts/backend.sh", {
  database_url_secret_name = module.secrets.database_url_secret_name
  frontend_url             = "http://${module.frontend.public_ip}"
  environment              = var.environment
  aws_region               = var.aws_region
})
```

`templatefile()` renders `backend.sh` as a template, replacing `${database_url_secret_name}`, `${environment}`, etc. with actual values at `terraform apply` time.

### Nginx Phase 1 Proxy Config
In Phase 1, Nginx on the frontend proxies `/api/` requests to the backend:
```nginx
location /api/ {
  proxy_pass http://<backend_private_ip>:3000/api/;
}
```
In Phase 2, this is removed — the ALB handles routing.

---

## Verify

```bash
# All 3 tiers running
terraform state list | grep "module\."

# BMI API health
curl http://$(terraform output -raw frontend_public_ip)/api/health

# Try adding a BMI record (replace with frontend IP)
curl -X POST http://$(terraform output -raw frontend_public_ip)/api/measurements \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","height":175,"weight":70}'
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Next Step

→ **[09-3tier-production](../09-3tier-production/README.md)** — move frontend to a private subnet and add ALB + HTTPS (Module 7, Phase 2).

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
