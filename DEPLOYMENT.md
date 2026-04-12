# Multi-Environment Deployment Guide

> **Who this is for:** Engineers who have completed Lessons 01-13 and want to deploy the BMI Health Tracker to real, isolated environments (dev / staging / prod) using a shared module library.
> **This is not a lesson** — it is the production-grade deployment workflow that builds on everything in the 13 lessons.

---

## Table of Contents

1. [How This Differs from the Lesson Folders](#1-how-this-differs-from-the-lesson-folders)
2. [Repository Structure](#2-repository-structure)
3. [Module Library](#3-module-library)
4. [Bootstrap — One-Time Setup](#4-bootstrap---one-time-setup)
5. [Deploying an Environment](#5-deploying-an-environment)
6. [Environment Comparison](#6-environment-comparison)
7. [Scripts Reference](#7-scripts-reference)
8. [Global Config Reference](#8-global-config-reference)
9. [State Management](#9-state-management)
10. [Operational Tasks](#10-operational-tasks)
11. [Destroying Environments](#11-destroying-environments)

---

## 1. How This Differs from the Lesson Folders

| Lesson Folders (01-13) | This Deployment System |
|---|---|
| Each folder self-contained | Shared modules in `modules/`, shared scripts in `scripts/` |
| Each lesson teaches one concept | Full production stack deployed in one apply |
| Local state (no S3 backend) | Remote S3 state, isolated per environment |
| Private module copies per lesson | One shared module library used by all environments |
| No multi-environment concept | dev / staging / prod isolated by S3 state key |

The lesson folders are for **learning**. This system is for **deploying**.

---

## 2. Repository Structure

```
terraform-iac-foundations-to-3tier/
|
+-- environments/           <- Deploy from here
|   +-- dev/
|   |   |-- main.tf         Module calls + S3 backend (dev/terraform.tfstate)
|   |   |-- variables.tf    8 variables, environment = "dev"
|   |   |-- outputs.tf      app_url, bastion_ip, db_endpoint, ssh commands
|   |   +-- terraform.tfvars.example
|   +-- staging/            Same structure, environment = "staging"
|   +-- prod/               Same structure, environment = "prod", multi_az = true
|
+-- modules/                <- Shared module library (used by all 3 environments)
|   +-- alb/                Application Load Balancer (HTTPS, path routing, Route53)
|   +-- ec2/                Generic EC2 (bastion, backend, frontend roles)
|   +-- iam/                IAM role + instance profile (Secrets Manager access)
|   +-- rds/                RDS PostgreSQL 14 (DB subnet group, parameter group)
|   +-- secrets/            AWS Secrets Manager (db-password + database-url)
|   +-- security-group/     5 security groups (ALB, bastion, frontend, backend, RDS)
|   +-- vpc/                Custom VPC (6 subnets, IGW, NAT GW, route tables)
|
+-- scripts/                <- User data scripts (referenced via templatefile())
|   +-- backend.sh          Node.js + PM2 + Secrets Manager credential fetch
|   +-- frontend.sh         Nginx + React build (Phase 1 and Phase 2 modes)
|   +-- single-instance.sh  All-tiers-on-one-box (lesson 06 equivalent)
|   +-- database.sh         PostgreSQL setup helper
|
+-- global/                 <- Reference templates (not deployed directly)
    +-- backend.tf          S3 backend block template + key naming convention
    +-- provider.tf         Standard provider + default_tags template
    +-- variables.tf        Shared variable definitions reference
```

---

## 3. Module Library

Each module in `modules/` is **consumed by** all three environment `main.tf` files via `source = "../../modules/<name>"`.

### Module Input/Output Summary

#### `modules/vpc`

| Key Input | Default | Notes |
|---|---|---|
| `project_name` | required | Used in resource names |
| `environment` | required | Used in resource names and tags |
| `vpc_cidr` | `10.0.0.0/16` | |
| `availability_zones` | `["ap-south-1a","ap-south-1b"]` | |

| Key Output | Value |
|---|---|
| `vpc_id` | VPC ID |
| `public_subnet_ids` | List of 2 public subnet IDs |
| `private_app_subnet_ids` | List of 2 private-app subnet IDs |
| `private_db_subnet_ids` | List of 2 private-db subnet IDs |
| `nat_gateway_public_ip` | Fixed public IP of NAT GW |

#### `modules/security-group`

| Key Input | Notes |
|---|---|
| `vpc_id` | From `module.vpc.vpc_id` |
| `allowed_ssh_cidr` | Your IP as `x.x.x.x/32` |
| `frontend_public_access` | `false` = ALB-only (production). `true` = direct internet (basic) |

Creates 5 security groups: ALB, bastion, frontend, backend, RDS.

| Key Output | Usage |
|---|---|
| `alb_sg_id` | Passed to `module.alb` |
| `bastion_sg_id` | Passed to `module.bastion` |
| `frontend_sg_id` | Passed to `module.frontend` |
| `backend_sg_id` | Passed to `module.backend` |
| `rds_sg_id` | Passed to `module.rds` |

#### `modules/iam`

Creates an IAM role + instance profile for EC2. Used by the backend instance to call `secretsmanager:GetSecretValue` without hardcoded credentials.

| Key Input | Default | Notes |
|---|---|---|
| `role_suffix` | `"backend"` | Role name: `<project>-<env>-backend-role` |
| `attach_ssm_policy` | `true` | Enables SSM Session Manager (no SSH needed) |
| `attach_cloudwatch_policy` | `false` | Enable in prod for CloudWatch metrics |

| Key Output | Usage |
|---|---|
| `instance_profile_name` | Passed to `module.backend.iam_instance_profile` |

#### `modules/rds`

RDS PostgreSQL 14 in a DB subnet group (private-db subnets).

| Key Input | dev | staging | prod |
|---|---|---|---|
| `instance_class` | `db.t3.micro` | `db.t3.small` | `db.t3.medium` |
| `multi_az` | `false` | `false` | `true` |
| `backup_retention_days` | `1` | `7` | `1` (demo) |
| `skip_final_snapshot` | `true` | `true` | `true` |
| `deletion_protection` | (default) | (default) | `false` (allow destroy) |
| `db_password` | From `module.secrets.db_password` | Same | Same |

| Key Output | Usage |
|---|---|
| `db_host` | Passed to `module.secrets` for connection string |
| `db_endpoint` | Root output for inspection |

**Note:** `db_password` is intentionally NOT an output — retrieve it via Secrets Manager only.

#### `modules/secrets`

Creates two AWS Secrets Manager secrets per environment:
- `<project>-<env>-db-password` — the database password (random, generated by module)
- `<project>-<env>-database-url` — full `postgresql://user:pass@host:5432/db` connection string

`recovery_window_days = 0` on all environments — secrets are immediately deleted on `terraform destroy` so re-apply works cleanly.

| Key Input | Notes |
|---|---|
| `db_host` | From `module.rds.db_host` |
| `recovery_window_days` | `0` — immediate deletion on destroy |

| Key Output | Usage |
|---|---|
| `db_password` | Passed to `module.rds.db_password` |
| `database_url_secret_name` | Passed to backend `templatefile()` |

#### `modules/ec2`

Generic EC2 module — reused for bastion, backend, and frontend with different inputs.

| Role | `instance_type` | `subnet_id` | `user_data` |
|---|---|---|---|
| bastion | `t3.micro` | `public_subnet_ids[0]` | none |
| backend | `t3.small/medium/large` | `private_app_subnet_ids[0]` | `templatefile(scripts/backend.sh, ...)` |
| frontend | `t3.micro/small/medium` | `private_app_subnet_ids[1]` | `templatefile(scripts/frontend.sh, ...)` |

#### `modules/alb`

Application Load Balancer with HTTPS termination, two target groups (frontend port 80, backend port 3000), and a Route53 A alias record.

| Key Input | Value |
|---|---|
| `certificate_arn` | ACM cert: `arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-...` |
| `hosted_zone_id` | `Z1019653XLWIJ02C53P5` |
| `domain_name` | `bmi.ostaddevops.click` |
| `frontend_instance_ids` | `[module.frontend.instance_id]` |
| `backend_instance_ids` | `[module.backend.instance_id]` |

---

## 4. Bootstrap - One-Time Setup

**Run this once before deploying any environment.** Creates the S3 bucket and DynamoDB table used for remote state storage.

```bash
cd 03-state-management/bootstrap
terraform init
terraform apply -auto-approve
```

This creates:
- S3 bucket: `terraform-state-bmi-ostaddevops` (versioned, AES-256 encrypted, public access blocked)
- DynamoDB table: `terraform-state-lock` (hash key: `LockID`, PAY_PER_REQUEST)

Verify:
```bash
aws s3 ls s3://terraform-state-bmi-ostaddevops --region ap-south-1
aws dynamodb describe-table --table-name terraform-state-lock --region ap-south-1 --query Table.TableStatus
# Expected: "ACTIVE"
```

**Do NOT destroy the bootstrap resources while any environment state exists in S3.**

---

## 5. Deploying an Environment

Replace `<env>` with `dev`, `staging`, or `prod`.

### Step 1: Configure Variables

```bash
cd environments/<env>
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — set your current IP:
```hcl
allowed_ssh_cidr = "203.0.113.45/32"   # curl ifconfig.me to get your IP
```

All other values have sensible defaults. The only required variable is `allowed_ssh_cidr`.

### Step 2: Initialize

```bash
terraform init
```

Terraform connects to S3, downloads the AWS and random providers, and resolves all 7 module sources from `../../modules/`.

Expected:
```
Initializing modules...
- alb in ../../modules/alb
- backend in ../../modules/ec2
- bastion in ../../modules/ec2
- frontend in ../../modules/ec2
- iam_backend in ../../modules/iam
- rds in ../../modules/rds
- secrets in ../../modules/secrets
- security_groups in ../../modules/security-group
- vpc in ../../modules/vpc

Terraform has been successfully initialized!
```

### Step 3: Plan

```bash
terraform plan -out=tfplan
```

Review the plan. Expected resource count varies by environment:

| Resource | Count |
|---|---|
| VPC + networking (module.vpc) | 19 |
| Security groups (module.security_groups) | 5 |
| IAM role + profile (module.iam_backend) | 3 |
| Secrets Manager secrets (module.secrets) | 2 |
| RDS subnet group + instance (module.rds) | 2 |
| EC2 instances (bastion + backend + frontend) | 3 |
| ALB + listeners + target groups + Route53 (module.alb) | ~10 |
| **Total** | **~44** |

### Step 4: Apply

```bash
terraform apply tfplan
```

Deployment takes 10-15 minutes. RDS takes the longest (~8 min). NAT Gateway takes ~2 min.

Expected final outputs:
```
Outputs:

app_url              = "https://bmi.ostaddevops.click"
bastion_public_ip    = "13.x.x.x"
db_endpoint          = "bmi-health-tracker-dev.xxx.ap-south-1.rds.amazonaws.com:5432"
database_url_secret  = "bmi-health-tracker-dev-database-url"
ssh_bastion          = "ssh -i sarowar-ostad-mumbai.pem ubuntu@13.x.x.x"
```

For prod, additional outputs:
```
alb_dns_name         = "bmi-...alb.ap-south-1.elb.amazonaws.com"
backend_private_ip   = "10.0.3.x"
frontend_private_ip  = "10.0.4.x"
ssh_backend          = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@<bastion> ubuntu@10.0.3.x"
ssh_frontend         = "ssh -i sarowar-ostad-mumbai.pem -J ubuntu@<bastion> ubuntu@10.0.4.x"
verify               = "curl https://bmi.ostaddevops.click/health"
```

### Step 5: Wait for User Data

Backend and frontend instances run bootstrap scripts on first boot (~3-5 minutes after `apply` completes).

Monitor:
```bash
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)

# SSH to bastion, then jump to backend
ssh -i sarowar-ostad-mumbai.pem -J ubuntu@$BASTION ubuntu@$BACKEND
sudo tail -f /var/log/user-data.log
```

### Step 6: Verify

```bash
curl -s https://bmi.ostaddevops.click/health | python3 -m json.tool
# Expected: {"status":"ok","database":"connected"}
```

---

## 6. Environment Comparison

| Setting | dev | staging | prod |
|---|---|---|---|
| State key | `dev/terraform.tfstate` | `staging/terraform.tfstate` | `prod/terraform.tfstate` |
| Backend EC2 | t3.small | t3.medium | t3.large |
| Frontend EC2 | t3.micro | t3.small | t3.medium |
| RDS instance | db.t3.micro | db.t3.small | db.t3.medium |
| RDS Multi-AZ | false | false | **true** |
| Backup retention | 1 day | 7 days | 1 day (demo) |
| CloudWatch policy | No | No | **Yes** |
| SSM policy | Yes | Yes | Yes |
| Deletion protection | default | default | **false** (allow destroy after demo) |
| `attach_cloudwatch_policy` | false | false | **true** |

All three environments are **fully isolated** — separate S3 state keys, separate named resources (tagged `Environment = dev/staging/prod`), separate Secrets Manager secrets.

---

## 7. Scripts Reference

Scripts in `scripts/` are loaded by environment `main.tf` files via `templatefile()`. They run as EC2 `user_data` on first boot.

### `backend.sh`

**Used by:** `module.backend` in all 3 environments

**Template variables injected by Terraform:**
```hcl
templatefile("../../scripts/backend.sh", {
  database_url_secret_name = module.secrets.database_url_secret_name
  frontend_url             = "https://${var.domain_name}"
  environment              = var.environment
  aws_region               = var.aws_region
})
```

**What it does:**
1. Installs AWS CLI v2, Node.js 18, PM2, PostgreSQL client
2. Fetches `DATABASE_URL` from Secrets Manager via `aws secretsmanager get-secret-value`
   - Uses the EC2 IAM instance profile (no hardcoded credentials)
3. Clones app from GitHub
4. `npm ci --production`
5. Writes `.env` from the fetched secret
6. Runs all `migrations/*.sql` files in sorted order
7. Starts backend with `pm2` + configures systemd restart on reboot

**Key security property:** The database password is never in the script, never in Terraform state output, and never in the boot log. Only the secret name is injected.

### `frontend.sh`

**Used by:** `module.frontend` in all 3 environments

**Template variables injected by Terraform:**
```hcl
templatefile("../../scripts/frontend.sh", {
  backend_private_ip = module.backend.private_ip
  phase              = "production"
})
```

**Two modes controlled by `phase` variable:**
- `phase = "basic"` — Nginx proxies `/api/*` directly to the backend private IP (Lesson 08 style)
- `phase = "production"` — ALB handles all routing; Nginx serves only static React files (all environments here use `"production"`)

**What it does:**
1. Installs Nginx, Node.js 18
2. Clones app and `npm run build` (Vite)
3. Deploys React build to `/var/www/html/`
4. Writes Nginx config (SPA mode — `try_files $uri /index.html`)
5. Starts Nginx

### `single-instance.sh`

**Used by:** Lesson 06 only (`06-ec2-deployment/scripts/single-instance.sh` is a copy). Not used by any environment here.

---

## 8. Global Config Reference

Files in `global/` are **reference templates** — they are not deployed as a standalone Terraform root. Copy patterns from them into new modules or environments.

### `global/provider.tf`

The canonical provider block for this project. All environments and lesson modules use this pattern:
```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "devops"
      Repository  = "terraform-iac-foundations-to-3tier"
    }
  }
}
```

### `global/backend.tf`

Template showing the S3 backend block with the correct bucket name, region, and key naming convention:
```hcl
backend "s3" {
  bucket         = "terraform-state-bmi-ostaddevops"
  key            = "<environment>/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

State key convention:
- Environments: `dev/terraform.tfstate`, `staging/terraform.tfstate`, `prod/terraform.tfstate`
- Lessons: `lessons/03-state-management/terraform.tfstate`

### `global/variables.tf`

Reference definitions for the four variables common to all modules: `aws_region`, `project_name`, `environment`, and `owner`.

---

## 9. State Management

### State Isolation per Environment

Each environment stores its Terraform state at a separate S3 key:

```
s3://terraform-state-bmi-ostaddevops/
  dev/terraform.tfstate        <- environments/dev state
  staging/terraform.tfstate    <- environments/staging state
  prod/terraform.tfstate       <- environments/prod state
```

Destroying `dev` (`terraform destroy` from `environments/dev/`) removes only the dev resources and clears `dev/terraform.tfstate`. Staging and prod are unaffected.

### State Locking

DynamoDB table `terraform-state-lock` prevents concurrent applies. If a previous apply was interrupted and the lock is stuck:

```bash
# Check for stuck lock
aws dynamodb scan \
  --table-name terraform-state-lock \
  --region ap-south-1 \
  --query "Items[].LockID.S" \
  --output text

# Force-unlock (use the lock ID from the error message)
terraform force-unlock <LOCK_ID>
```

### Inspecting Remote State

```bash
cd environments/dev

# List all managed resources
terraform state list

# Show details of a specific resource
terraform state show module.rds.aws_db_instance.main

# Pull state to a local file
terraform state pull > dev-backup.tfstate
```

---

## 10. Operational Tasks

### Update SSH CIDR (IP Changed)

```bash
cd environments/<env>
# Edit terraform.tfvars: allowed_ssh_cidr = "NEW_IP/32"
terraform plan    # verify only security_group change
terraform apply
```

Security group updates are in-place — no EC2 replacement.

### SSH Into Backend via Bastion

```bash
BASTION=$(terraform -chdir=environments/dev output -raw bastion_public_ip)
BACKEND=$(terraform -chdir=environments/dev output -raw backend_private_ip)

ssh -i sarowar-ostad-mumbai.pem \
    -J ubuntu@$BASTION \
    ubuntu@$BACKEND
```

Or use the pre-built output:
```bash
terraform -chdir=environments/dev output -raw ssh_backend
# Copy-paste the printed command
```

### Retrieve the Database Password

```bash
aws secretsmanager get-secret-value \
  --secret-id "bmi-health-tracker-dev-db-password" \
  --region ap-south-1 \
  --query SecretString \
  --output text
```

Never hardcode this value anywhere — always fetch it at runtime.

### Scale Instance Type

Edit `environments/<env>/main.tf` — change `instance_type` on the relevant module:
```hcl
module "backend" {
  instance_type = "t3.medium"   # was t3.small
  ...
}
```

```bash
terraform plan    # shows: ~ module.backend.aws_instance.this (instance_type: t3.small -> t3.medium)
terraform apply   # instance is stopped, resized, restarted (~2 min downtime)
```

### Force Re-provision an Instance (Re-run User Data)

```bash
# Replaces the instance — runs user_data again from scratch
terraform apply -replace="module.backend.aws_instance.this"
```

### Check Backend Health from Bastion

```bash
# SSH to bastion first, then:
curl http://<backend_private_ip>:3000/health
# Expected: {"status":"ok","database":"connected"}
```

---

## 11. Destroying Environments

### Destroy a Single Environment

```bash
cd environments/dev
terraform destroy -auto-approve
```

Destruction order (Terraform handles automatically):
1. Route53 record
2. ALB + listeners + target groups
3. EC2 instances (bastion, backend, frontend)
4. Secrets Manager secrets (immediate deletion — `recovery_window_days = 0`)
5. RDS instance (no final snapshot — `skip_final_snapshot = true`)
6. RDS subnet group
7. IAM instance profile + role
8. Security groups
9. NAT Gateway (~60 sec)
10. Elastic IP
11. Internet Gateway
12. Subnets (6)
13. VPC

Expected:
```
Destroy complete! Resources: 44 destroyed.
```

### Destroy All Environments

```bash
cd environments/dev     && terraform destroy -auto-approve && cd ../..
cd environments/staging && terraform destroy -auto-approve && cd ../..
cd environments/prod    && terraform destroy -auto-approve && cd ../..
```

### Destroy Bootstrap (Only When Completely Done)

**Only do this when you are permanently done with the repository.**
Destroying bootstrap deletes all remote state — this cannot be undone.

```bash
cd 03-state-management/bootstrap
terraform destroy -auto-approve
```

### Verify Nothing Remains

```bash
# Check for running EC2 instances
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Project,Values=bmi-health-tracker" "Name=instance-state-name,Values=running,stopped,pending" \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

# Check for RDS instances
aws rds describe-db-instances \
  --region ap-south-1 \
  --query "DBInstances[?contains(DBInstanceIdentifier,'bmi')].{ID:DBInstanceIdentifier,State:DBInstanceStatus}" \
  --output table

# Check for NAT Gateways (most expensive if left running)
aws ec2 describe-nat-gateways \
  --region ap-south-1 \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].{ID:NatGatewayId,State:State}" \
  --output table
```

All queries should return empty tables after a successful destroy.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
