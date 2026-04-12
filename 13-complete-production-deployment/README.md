# 13 — Complete Production Deployment

> **Module 8: Full Production Architecture — All Modules Together**
> Deploy the complete BMI Health Tracker 3-tier application to production. Every module works together. HTTPS, Route53, RDS Multi-AZ, Secrets Manager, ALB path routing.

---

## What You Will Learn

- Composing a production deployment from reusable modules
- Why everything is parameterized (no hardcoded values)
- Optional S3 remote state for this lesson
- RDS `multi_az = true` for automatic failover
- Verifying the complete end-to-end flow
- The `terraform destroy` strategy for demo cleanup
- Reading a multi-module `terraform plan` output

---

## Architecture

```
Internet
    │
    ├── DNS: bmi.ostaddevops.click (Route53 → ALB alias)
    │
    ▼ HTTPS:443 (ACM TLS cert) / HTTP:80 (301 redirect)
Application Load Balancer  ←─── Public Subnets (10.0.1.0/24, 10.0.2.0/24)
    │
    ├── /api/*  →  Backend Target Group  →  Backend EC2  :3000  [Private-App]
    │                                         └── IAM Role → Secrets Manager
    └── /*      →  Frontend Target Group →  Frontend EC2 :80   [Private-App]
                                              └── Nginx serves React /dist

Bastion EC2  [Public Subnet]  ─── SSH from YOUR_IP/32 only
    └── ProxyJump → Backend
    └── ProxyJump → Frontend

RDS PostgreSQL 14  [Private-DB Subnets, Multi-AZ]
    └── db.t3.medium, gp3, encrypted, no public access

NAT Gateway  [Public Subnet]
    └── Outbound internet for private subnets

Secrets Manager:
    ├── /production/bmi-health-tracker/db-password
    └── /production/bmi-health-tracker/database-url

S3 Remote State:
    └── terraform-state-bmi-ostaddevops/prod/terraform.tfstate
```

---

## Folder Structure

```
13-complete-production-deployment/
├── main.tf                  ← all 7 modules orchestrated (with commented S3 backend)
├── variables.tf             ← all configurable parameters
├── outputs.tf               ← verify_steps map, app_url, ssh_command, destroy_reminder
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
├── modules/
│   ├── vpc/                 ← VPC + 6 subnets + IGW + NAT GW
│   ├── security-group/      ← 5 SGs, Phase 2 rules (frontend_public_access=false)
│   ├── iam/                 ← Least-privilege role for backend EC2
│   ├── rds/                 ← PostgreSQL 14, multi_az=true, db.t3.medium
│   ├── secrets/             ← random_password → Secrets Manager
│   ├── ec2/                 ← Used for bastion, backend, frontend
│   └── alb/                 ← ALB + TGs + HTTPS + Route53 A record
└── scripts/
    ├── backend.sh           ← Node.js + PM2 bootstrap
    └── frontend.sh          ← Nginx + React build (phase=production)
```

---

## Prerequisites

- All previous lessons (01-12) completed or understood
- AWS CLI configured
- (Optional) Bootstrap state bucket exists: run `03-state-management/bootstrap/` first

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
environment             = "production"
key_name                = "sarowar-ostad-mumbai"
allowed_ssh_cidr        = "YOUR_IP/32"   # curl ifconfig.me
frontend_instance_type  = "t3.medium"
backend_instance_type   = "t3.large"
db_instance_class       = "db.t3.medium"

# Pre-provisioned — do not change
certificate_arn = "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0"
hosted_zone_id  = "Z1019653XLWIJ02C53P5"
domain_name     = "bmi.ostaddevops.click"
```

### Step 2: (Optional) Enable Remote State

Open `main.tf` and uncomment the `backend "s3"` block (requires bootstrap to run first):
```hcl
backend "s3" {
  bucket         = "terraform-state-bmi-ostaddevops"
  key            = "prod/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```
Then run `terraform init` again and confirm state migration.

### Step 3: Review the Plan

```bash
terraform init
terraform plan
```

Important: read through the entire plan. You will see **~45+ resources**. Verify:
- All `modules.vpc.*` resources show correct CIDRs
- `modules.rds.*` shows `multi_az = true`
- `modules.alb.*` shows the correct certificate ARN
- No existing resources will be destroyed

### Step 4: Deploy

```bash
terraform apply
```

**Expected timeline:**
| Phase | Duration |
|-------|----------|
| VPC, SGs, IAM, Secrets | ~1 min |
| RDS (multi_az provisioning) | ~8-12 min |
| EC2 instances (user_data running) | ~3-5 min |
| ALB health checks passing | ~2-3 min |
| **Total** | **~15-20 min** |

### Step 5: Run the Verify Steps

```bash
terraform output verify_steps
```

This outputs a map with exact `curl` commands to verify each layer. Run them in order:
```
1. health_check    → curl https://bmi.ostaddevops.click/health
2. api_test        → curl https://bmi.ostaddevops.click/api/measurements
3. https_redirect  → curl -I http://bmi.ostaddevops.click
4. frontend_ui     → open https://bmi.ostaddevops.click in browser
```

### Step 6: Verify Each Layer

```bash
# Health check endpoint
curl https://bmi.ostaddevops.click/health
# Expected: {"status":"ok","environment":"production"}

# API
curl https://bmi.ostaddevops.click/api/measurements
# Expected: {"measurements":[...]} or empty array

# Add a BMI record
curl -X POST https://bmi.ostaddevops.click/api/measurements \
  -H "Content-Type: application/json" \
  -d '{"name":"Demo User","height":175,"weight":70}'
# Expected: {"id":1,"name":"Demo User",...}

# HTTP → HTTPS redirect
curl -I http://bmi.ostaddevops.click
# Expected: 301 Moved Permanently, Location: https://...

# Open in browser
echo "Open: https://bmi.ostaddevops.click"
```

### Step 7: Inspect the Deployed Architecture

```bash
# All resources in state
terraform state list | sort

# ALB target health (should show "healthy")
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw frontend_tg_arn) \
  --query "TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}" \
  --output table

# RDS multi-AZ status
aws rds describe-db-instances \
  --query "DBInstances[?DBName=='bmidb'].{ID:DBInstanceIdentifier,MultiAZ:MultiAZ,Status:DBInstanceStatus}" \
  --output table

# Secrets created
aws secretsmanager list-secrets \
  --filter Key=name,Values=/production/bmi-health-tracker/ \
  --query "SecretList[].Name" \
  --output table
```

### Step 8: Destroy After Class

```bash
terraform destroy
```

Type `yes` to confirm. Teardown time: ~10-15 min (RDS deletion takes longest).

```bash
# Verify everything is destroyed
terraform state list
# Expected: (empty)

aws ec2 describe-instances \
  --filters "Name=tag:Environment,Values=production" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected: (empty)
```

---

## Module Composition Map

```
main.tf
  ├── module.vpc              → modules/vpc/
  ├── module.security_groups  → modules/security-group/  (uses module.vpc.vpc_id)
  ├── module.iam_backend      → modules/iam/
  ├── module.rds              → modules/rds/              (uses module.vpc.private_db_subnet_ids)
  ├── module.secrets          → modules/secrets/          (uses module.rds.db_host)
  ├── module.bastion          → modules/ec2/              (uses module.vpc.public_subnet_ids[0])
  ├── module.backend          → modules/ec2/              (uses module.secrets, module.iam_backend)
  ├── module.frontend         → modules/ec2/              (uses module.backend.private_ip)
  └── module.alb              → modules/alb/              (uses module.frontend, module.backend, module.vpc)
```

### Dependency Order (Terraform resolves automatically)
```
vpc → security_groups
vpc → rds → secrets
vpc + secrets → backend
backend → frontend
vpc + frontend + backend + security_groups → alb
```

---

## Cost Estimate (Running During Class)

| Resource | Instance/Config | ~Cost/hour |
|----------|-----------------|------------|
| Backend EC2 | t3.large | $0.083 |
| Frontend EC2 | t3.medium | $0.0416 |
| Bastion EC2 | t3.micro | $0.0104 |
| RDS PostgreSQL | db.t3.medium, Multi-AZ | $0.136 |
| ALB | per hour | $0.008 |
| NAT Gateway | per hour | $0.045 |
| **Total** | | **~$0.32/hour** |

A 2-hour class costs ~$0.66. Always run `terraform destroy` after.

---

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| ALB health checks failing | `/var/log/user-data.log` on EC2 | Wait 5 more min; check PM2 status |
| 502 Bad Gateway | Backend not running | SSH to backend, check `pm2 status` |
| `https://` shows cert error | ACM cert validation | Certificate ARN must match domain |
| `curl: (6) Could not resolve host` | Route53 propagation | Wait 1-2 min; try `nslookup` |
| RDS connection refused | user_data still running | Wait for `cloud-init status: done` |

---

## Destroy Reminder

```bash
terraform output destroy_reminder
```

> After class, always run:
> `terraform destroy`
> This removes ALL resources to avoid AWS charges.
> Estimated cost if left running overnight: ~$7.70

---

## You've Completed the Full Journey

```
01 — First EC2          → IaC basics
02 — EC2 + SG           → data sources, locals
03 — State              → S3 backend, DynamoDB lock
04 — Modules            → reusable components
05 — VPC                → 6 subnets, IGW, NAT GW
06 — Single Instance    → Module 4 automation
07 — RDS                → managed database
08 — 3-Tier Basic       → Phase 1 public frontend
09 — 3-Tier Production  → Phase 2 ALB + HTTPS
10 — Security           → least privilege, encryption
11 — User Data          → templatefile() scripts
12 — Bastion Host       → ProxyJump SSH
13 — THIS FOLDER        → everything in production ✓
```

→ For managing multiple environments (dev/staging/prod) see the **[environments/](../environments/)** folder.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
