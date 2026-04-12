# BMI Health Tracker - Terraform IaC: Foundations to 3-Tier

> **Production-grade Terraform learning repository for AWS infrastructure engineering.**
> Evolves the BMI Health Tracker from a manually-provisioned single server (Module 4) through 13 progressive lessons to a fully automated, HTTPS-terminated, privately-networked, multi-environment 3-tier deployment on AWS.

This repository serves two purposes simultaneously: a **structured teaching curriculum** for Modules 4, 7, and 8 of the Ostad DevOps course, and a **reference architecture** for real-world cloud infrastructure. Every lesson is self-contained and buildable in isolation. The shared module library and environment configs represent production deployment patterns.

---

## What is Terraform?

[Terraform](https://www.terraform.io/) is an open-source **Infrastructure as Code (IaC)** tool created by HashiCorp. It lets you define cloud and on-premises resources in human-readable configuration files and then provision, update, and destroy that infrastructure consistently and repeatably.

Instead of clicking through the AWS Console or running imperative shell scripts, you write declarative `.tf` files that describe the **desired end state** of your infrastructure. Terraform figures out what needs to be created, changed, or deleted to reach that state.

Official site: **[https://www.terraform.io](https://www.terraform.io)**  
Registry (providers & modules): **[https://registry.terraform.io](https://registry.terraform.io)**  
Documentation: **[https://developer.hashicorp.com/terraform/docs](https://developer.hashicorp.com/terraform/docs)**

---

## Why Use Terraform?

| Pain point without IaC | How Terraform solves it |
|---|---|
| Manual console clicks — error-prone and slow | Declare resources once in code, apply in seconds |
| "It works on my account" — no reproducibility | Same `.tf` files produce identical infra everywhere |
| No history of what changed or why | Changes live in Git — full audit trail and blame |
| Spinning up dev/staging/prod is a week's work | Reuse modules with different `tfvars` per environment |
| Tearing down infra is forgotten and costs money | `terraform destroy` removes everything cleanly |
| Multi-cloud complexity | Single tool covers AWS, Azure, GCP, and 1 000+ providers |

---

## Benefits of Terraform

**1. Declarative syntax** — Describe *what* you want, not *how* to build it. Terraform translates your intent into the correct sequence of API calls.

**2. Execution plan (`terraform plan`)** — Preview every change before it touches real infrastructure. No surprises in production.

**3. State management** — Terraform tracks the real state of deployed resources in a state file, enabling it to detect drift and apply only the minimum necessary changes.

**4. Modules** — Reusable, versioned building blocks. Write a VPC module once, use it across dev, staging, and prod with one line.

**5. Provider ecosystem** — Over 3 000 providers on the Terraform Registry cover every major cloud, SaaS, and platform API.

**6. Team collaboration** — Remote state backends (S3 + DynamoDB in this repo) enable locking and sharing so multiple engineers can work safely on the same infrastructure.

**7. Idempotent** — Running `terraform apply` multiple times produces the same result. No side-effects from re-running.

**8. Immutable infrastructure** — Encourages replacing resources rather than patching them, reducing configuration drift and debugging time.

---

## Table of Contents

1. [Technology Stack](#1-technology-stack)
2. [Architecture Overview](#2-architecture-overview)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [First-Time Setup](#5-first-time-setup)
6. [Lesson-by-Lesson Guide](#6-lesson-by-lesson-guide)
7. [Running the Full Application](#7-running-the-full-application)
8. [SSH Access and Operations](#8-ssh-access-and-operations)
9. [Secrets and Credentials](#9-secrets-and-credentials)
10. [Module Reference](#10-module-reference)
11. [Making Changes Safely](#11-making-changes-safely)
12. [Cost and Cleanup](#12-cost-and-cleanup)
13. [Troubleshooting](#13-troubleshooting)
14. [Key Design Decisions](#14-key-design-decisions)

---

## 1. Technology Stack

### Application

| Layer | Technology | Version | Role |
|---|---|---|---|
| Frontend | React | 18 | Single-page app, built with Vite |
| Backend | Node.js + Express | 18 LTS | REST API, process-managed by PM2 |
| Database | PostgreSQL | 14 | Relational store, managed by AWS RDS |
| Web Server | Nginx | 1.x | Reverse proxy + static file server |
| Process Manager | PM2 | latest | Auto-restart, systemd integration |

### Infrastructure and Tooling

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5.0 | Infrastructure as Code |
| AWS Provider | ~> 5.0 | AWS resource management |
| Random Provider | ~> 3.5 | Cryptographic password generation |
| AWS CLI | v2 | Verification, secret retrieval, state operations |
| Git | any | Source control |

### AWS Services

| Service | Lesson Introduced | Purpose |
|---|---|---|
| EC2 (Ubuntu 22.04 LTS) | 01 | Compute: frontend, backend, bastion |
| Security Groups | 02 | Stateful firewall rules |
| VPC + Subnets + IGW + NAT GW | 05 | Network isolation (3 tiers) |
| S3 | 03 | Terraform remote state storage |
| DynamoDB | 03 | Terraform state locking |
| RDS PostgreSQL 14 | 07 | Managed database |
| IAM Roles + Instance Profiles | 08 | Least-privilege credential delivery |
| Secrets Manager | 07 | Zero-plaintext credential management |
| Application Load Balancer | 09 | HTTPS termination + path-based routing |
| ACM (Certificate Manager) | 09 | TLS certificate lifecycle |
| Route53 | 09 | DNS record management |
| SSM Session Manager | 10 | Agentless shell access (no port 22) |
| CloudWatch | 10 | Logs and metrics |
| EBS (gp3 encrypted) | 01 | Root block storage |
| Elastic IP | 05 | Fixed public IP for NAT Gateway |

### Fixed Infrastructure Identifiers

| Resource | Value |
|---|---|
| AWS Region | `ap-south-1` (Mumbai) |
| EC2 Key Pair | `sarowar-ostad-mumbai` |
| Application Domain | `bmi.ostaddevops.click` |
| Route53 Hosted Zone ID | `Z1019653XLWIJ02C53P5` |
| ACM Certificate ARN | `arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0` |
| Terraform State Bucket | `terraform-state-bmi-ostaddevops` |
| State Lock Table | `terraform-state-lock` |

---

## 2. Architecture Overview

### Production Architecture (Lesson 09 / 13 / environments/prod)

```
INTERNET
    |
    v  (DNS lookup)
Route53 A alias: bmi.ostaddevops.click
    |
    v
Application Load Balancer  (public subnets: 10.0.1.0/24 + 10.0.2.0/24, 2 AZs)
    |-- HTTP :80  --->  301 Redirect to HTTPS
    |-- HTTPS :443  (ACM TLS cert, ELBSecurityPolicy-TLS13-1-2-2021-06)
         |
         |-- path /api/*  ---------->  Backend Target Group
         |-- path /health ---------->  Backend Target Group
         +-- path /* (default) ----->  Frontend Target Group
                  |                         |
                  v                         v
         Backend EC2 :3000          Frontend EC2 :80
         Node.js + PM2              Nginx + React SPA
         private-app-1a             private-app-1b
         (10.0.3.0/24)              (10.0.4.0/24)
                  |
                  | (reads at boot via IAM role)
                  v
         AWS Secrets Manager
         bmi-health-tracker-prod-database-url
                  |
                  v
         RDS PostgreSQL 14  (private-db subnets: 10.0.5.0/24 + 10.0.6.0/24)
         db.t3.medium, Multi-AZ, encrypted, Performance Insights

Bastion EC2 (public-1a: 10.0.1.0/24)
    port 22 <-- your IP /32 ONLY
    ProxyJump --> backend (10.0.3.x)
    ProxyJump --> frontend (10.0.4.x)

NAT Gateway (public-1a: 10.0.1.0/24)
    outbound internet for private subnets (apt, npm, git)
```

### VPC CIDR Layout

```
VPC: 10.0.0.0/16 (ap-south-1, Mumbai)
|
+-- ap-south-1a
|   +-- 10.0.1.0/24  public-1a       <- ALB, Bastion, NAT Gateway
|   +-- 10.0.3.0/24  private-app-1a  <- Backend EC2
|   +-- 10.0.5.0/24  private-db-1a   <- RDS primary
|
+-- ap-south-1b
    +-- 10.0.2.0/24  public-1b       <- ALB (ALB requires 2+ AZs)
    +-- 10.0.4.0/24  private-app-1b  <- Frontend EC2
    +-- 10.0.6.0/24  private-db-1b   <- RDS standby (Multi-AZ failover)
```

### Security Group Chain

Traffic flows through a strict chain - no tier can be reached by skipping a layer:

```
Internet -> ALB-SG (:443)
ALB-SG   -> Frontend-SG (:80)     -> Frontend EC2 (Nginx)
ALB-SG   -> Backend-SG  (:3000)   -> Backend EC2 (Node.js)
Bastion-SG (:22 from YOUR_IP/32)  -> Bastion EC2
Bastion-SG -> Backend-SG  (:22)   -> Backend EC2 (ProxyJump)
Bastion-SG -> Frontend-SG (:22)   -> Frontend EC2 (ProxyJump)
Backend-SG -> RDS-SG      (:5432) -> RDS PostgreSQL
```

The private-db route table has no internet route - RDS cannot initiate or receive any internet traffic even if all security group rules were removed.

### Phase 1 vs Phase 2 (Module 7)

The repository teaches the evolution from a basic 3-tier setup to production:

| Dimension | Phase 1 - Basic (Lesson 08) | Phase 2 - Production (Lesson 09+) |
|---|---|---|
| Frontend location | Public subnet (public IP) | Private subnet (no public IP) |
| Frontend access | Port 80 from internet directly | Port 80 from ALB-SG only |
| ALB | None | Internet-facing, multi-AZ |
| TLS / HTTPS | No | ACM cert, TLS 1.3 |
| DNS | IP address | bmi.ostaddevops.click |
| Nginx role | Proxy /api/* to backend IP | Serve static files only |
| Terraform switch | `frontend_public_access = true` | `frontend_public_access = false` |

One variable controls the entire difference between Phase 1 and Phase 2.

---

## 3. Repository Structure

```
terraform-iac-foundations-to-3tier/
|
+-- LESSON FOLDERS  (fully self-contained — no external dependencies)
|   +-- 01-terraform-fundamentals/      First EC2, data aws_ami, init/plan/apply/destroy
|   +-- 02-terraform-aws-basics/        EC2 + SG, locals, default_tags, user_data heredoc
|   +-- 03-state-management/            S3 backend, DynamoDB lock
|   |   +-- bootstrap/                 Run once: creates S3 bucket + DynamoDB table
|   +-- 04-modules/                     Local module pattern, modules/webserver/
|   +-- 05-networking-vpc/              Full custom VPC, 6 subnets, IGW, NAT GW
|   +-- 06-ec2-deployment/              Module 4 automated: 3 tiers on 1 EC2
|   +-- 07-rds-database/               Managed RDS, Secrets Manager, private subnet
|   +-- 08-3tier-basic/                Phase 1: public frontend, private backend
|   +-- 09-3tier-production/           Phase 2: ALB, HTTPS, private frontend, Route53
|   +-- 10-security-best-practices/    IAM least-privilege, SSM Session Manager
|   +-- 11-user-data-automation/       templatefile() deep dive, cloud-init patterns
|   +-- 12-bastion-host/               SSH bastion, ProxyJump -J, ~/.ssh/config
|   +-- 13-complete-production-deployment/ Final: all 7 modules assembled, Multi-AZ
|
+-- SHARED MODULE LIBRARY  (source of truth — copied into lesson folders)
|   +-- modules/
|       +-- vpc/            VPC, 6 subnets, IGW, EIP, NAT GW, 3 route tables, 6 RTA
|       +-- security-group/ 5 SGs (ALB, bastion, frontend, backend, RDS)
|       +-- ec2/            Generic EC2 (Ubuntu 22.04, gp3 encrypted, create_before_destroy)
|       +-- alb/            ALB + 2 TGs + HTTPS + path rules + Route53 A alias
|       +-- rds/            PostgreSQL 14, encrypted, Multi-AZ capable, Performance Insights
|       +-- secrets/        random_password -> Secrets Manager (db-password + database-url)
|       +-- iam/            EC2 instance role, scoped Secrets Manager policy
|
+-- SCRIPTS  (user_data templates — loaded via templatefile() or file())
|   +-- scripts/
|       +-- backend.sh          Node.js + PM2 + DATABASE_URL from Secrets Manager
|       +-- frontend.sh         Nginx + React build (phase=basic or phase=production)
|       +-- single-instance.sh  All 3 tiers on 1 box (lesson 06 pattern)
|       +-- database.sh         SQL migration runner via bastion
|
+-- MULTI-ENVIRONMENT DEPLOYMENTS  (prod-level: shared modules, S3 state isolation)
|   +-- environments/
|   |   +-- dev/             t3.small/micro, db.t3.micro, multi_az=false
|   |   +-- staging/         t3.medium/small, db.t3.small, multi_az=false
|   |   +-- prod/            t3.large/medium, db.t3.medium, multi_az=true
|   +-- global/
|       +-- provider.tf     AWS provider + default_tags reference template
|       +-- variables.tf    Shared variable definitions reference
|       +-- backend.tf      S3 backend block template with key naming convention
|
+-- .gitignore         Blocks: .terraform/, *.tfstate, *.tfvars, *.pem, .env
+-- README.md          This file
+-- DEPLOYMENT.md      Full multi-environment deployment guide (environments/ + modules/)
```

### Self-Contained Lesson Design

Every numbered lesson folder (01-13) is **completely independent**. It contains:

- `main.tf`, `variables.tf`, `outputs.tf` - the lesson's Terraform configuration
- `terraform.tfvars.example` - copy to `terraform.tfvars`, set your IP
- `README.md` - complete step-by-step guide for that specific lesson
- `modules/` - private copies of all modules the lesson needs (no `../` references)
- `scripts/` - private copies of required user_data scripts (where applicable)

You can `cd` into any lesson folder and run `terraform init && terraform apply` without touching anything outside of it.

---

## 4. Prerequisites

### Required Tools

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Git | any | https://git-scm.com |

### Verify Everything is Installed

```bash
terraform version
# Terraform v1.x.x  (must be >= 1.5.0)

aws --version
# aws-cli/2.x.x

aws sts get-caller-identity
# Returns: {"UserId":..., "Account":"388779989543", "Arn":...}
# If this fails: run "aws configure" first
```

### Configure AWS Credentials

```bash
# Interactive setup (recommended)
aws configure
# AWS Access Key ID:     <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region:        ap-south-1
# Default output format: json

# OR: environment variables (CI/CD)
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="ap-south-1"
```

### Pre-Existing AWS Resources

These resources are already provisioned for this project and are referenced by ARN/ID:

| Resource | Value | Notes |
|---|---|---|
| EC2 Key Pair | `sarowar-ostad-mumbai` | Must exist in ap-south-1 before any lesson |
| ACM Certificate | `arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-...` | For bmi.ostaddevops.click |
| Route53 Hosted Zone | `Z1019653XLWIJ02C53P5` | For ostaddevops.click |

Verify the key pair exists:
```bash
aws ec2 describe-key-pairs \
  --key-names sarowar-ostad-mumbai \
  --region ap-south-1 \
  --query "KeyPairs[0].KeyName" \
  --output text
# Expected: sarowar-ostad-mumbai
```

Set the correct file permissions on the private key:
```bash
chmod 400 ~/sarowar-ostad-mumbai.pem
```

### Get Your Current Public IP

SSH security groups restrict access to a specific IP. Before every lesson:

```bash
curl -s ifconfig.me
# Example output: 203.0.113.45
# Use as: allowed_ssh_cidr = "203.0.113.45/32"
```

If your IP changes (VPN, network switch, new session), re-run `terraform apply` with the updated IP — only the security group rule is modified.

### IAM Permissions Required

Your AWS user/role needs at minimum:

```
EC2: full (instances, SGs, VPC, keypairs, AMIs, EBS)
RDS: full (instances, subnet groups, parameter groups)
ELB: full (ALB, listeners, target groups)
Route53: ChangeResourceRecordSets on the hosted zone
ACM: ListCertificates, DescribeCertificate
Secrets Manager: full (create/read/delete secrets)
IAM: CreateRole, AttachRolePolicy, CreateInstanceProfile, PassRole
S3: full on terraform-state-bmi-ostaddevops bucket
DynamoDB: full on terraform-state-lock table
```

`AdministratorAccess` covers all of the above.

---

## 5. First-Time Setup

### Step 1: Clone the Repository

```bash
git clone https://github.com/md-sarowar-alam/terraform-iac-foundations-to-3tier.git
cd terraform-iac-foundations-to-3tier
```

### Step 2: Bootstrap Remote State (Once Per AWS Account)

Before Lessons 03-13 or before deploying any `environments/` folder, create the S3 state backend:

```bash
cd 03-state-management/bootstrap
terraform init
terraform apply -auto-approve
cd ../..
```

This creates:
- S3 bucket `terraform-state-bmi-ostaddevops` — versioned, AES-256 encrypted, public access blocked, `prevent_destroy = true`
- DynamoDB table `terraform-state-lock` — PAY_PER_REQUEST billing, hash key `LockID`

Verify:
```bash
aws s3 ls s3://terraform-state-bmi-ostaddevops --region ap-south-1

aws dynamodb describe-table \
  --table-name terraform-state-lock \
  --region ap-south-1 \
  --query "Table.TableStatus" \
  --output text
# Expected: ACTIVE
```

**Critical:** Never destroy the bootstrap resources while any environment's remote state is stored in S3. Doing so makes that environment's infrastructure unmanageable by Terraform.

### Step 3: Confirm Everything is Ready

```bash
# Key pair accessible
ls -la ~/sarowar-ostad-mumbai.pem

# AWS credentials working
aws sts get-caller-identity --region ap-south-1

# Terraform version
terraform version | head -1
```

---

## 6. Lesson-by-Lesson Guide

### Learning Progression

| # | Folder | Topic | What is Built | Key Patterns |
|---|---|---|---|---|
| 01 | `01-terraform-fundamentals` | First EC2 | Single EC2, no SG | `init/plan/apply/destroy`, `data "aws_ami"`, state file |
| 02 | `02-terraform-aws-basics` | EC2 + Security Group | EC2 + SG + user_data | `locals`, `default_tags`, heredoc user_data, `data "aws_vpc"` |
| 03 | `03-state-management` | Remote State | S3 backend + lock | `backend "s3"`, DynamoDB, `terraform state` commands |
| 04 | `04-modules` | Module Pattern | EC2 via reusable module | `module` block, inputs/outputs, `source = "./modules/"` |
| 05 | `05-networking-vpc` | Custom VPC | 6 subnets, IGW, NAT GW | `count`, `[*]` splat, `depends_on`, route tables |
| 06 | `06-ec2-deployment` | Module 4 Automated | All 3 tiers on 1 EC2 | `file()` for scripts, `data "aws_subnets"`, `tolist()` |
| 07 | `07-rds-database` | Managed RDS | RDS + Secrets Manager | `random_password`, DB subnet group, `sensitive = true` |
| 08 | `08-3tier-basic` | 3-Tier Phase 1 | Frontend public + Backend private | IAM instance profile, `templatefile()`, SG chain |
| 09 | `09-3tier-production` | 3-Tier Phase 2 | ALB + HTTPS + private frontend | ALB listeners, path rules, ACM, Route53 alias |
| 10 | `10-security-best-practices` | Security Hardening | All from 09 + SSM | Least-privilege IAM, SSM Session Manager |
| 11 | `11-user-data-automation` | User Data Deep Dive | All from 10 + advanced cloud-init | `templatefile()` variables, `$$` escaping |
| 12 | `12-bastion-host` | Bastion + Jump Box | Bastion EC2 + SSH ProxyJump | `ProxyJump -J`, `~/.ssh/config`, SG layering |
| 13 | `13-complete-production-deployment` | Full Production | All 7 modules assembled | Multi-AZ RDS, `deletion_protection`, complete verification |

### Per-Lesson Workflow (All Lessons)

```bash
cd XX-lesson-name

# 1. Copy and configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set allowed_ssh_cidr = "$(curl -s ifconfig.me)/32"

# 2. Initialize — downloads providers and resolves module sources
terraform init

# 3. Preview — review ALL changes before touching AWS
terraform plan

# 4. Deploy
terraform apply

# 5. Test the lesson (see each lesson's README.md for specific verification steps)

# 6. IMPORTANT: Destroy after each lesson to stop AWS charges
terraform destroy -auto-approve
```

Each lesson folder's `README.md` contains full step-by-step instructions, all verification commands, common errors with fixes, and an explanation of every new pattern introduced.

---

## 7. Running the Full Application

### Option A: Complete Production Deployment (Lesson 13)

The single-lesson production assembly — all 7 modules together:

```bash
cd 13-complete-production-deployment
cp terraform.tfvars.example terraform.tfvars
# Edit: allowed_ssh_cidr = "YOUR_IP/32"

terraform init
terraform plan
terraform apply   # ~15-20 minutes (RDS takes longest)
```

Verify end-to-end:
```bash
# HTTPS health check
curl -s https://bmi.ostaddevops.click/health | python3 -m json.tool
# Expected: {"status":"ok","database":"connected"}

# API works
curl -s https://bmi.ostaddevops.click/api/measurements
# Expected: []  (empty array on fresh deployment)

# HTTP -> HTTPS redirect
curl -sI http://bmi.ostaddevops.click
# Expected: HTTP/1.1 301 Moved Permanently

# Open in browser
terraform output -raw app_url
```

### Option B: Single-Instance Quick Demo (Lesson 06)

The Module 4 equivalent — all 3 tiers on one EC2, no custom VPC:

```bash
cd 06-ec2-deployment
cp terraform.tfvars.example terraform.tfvars
# Edit: allowed_ssh_cidr = "YOUR_IP/32"

terraform init
terraform apply   # ~1 min to create. 3-5 min for user_data to complete.

# Monitor bootstrap progress
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
sudo tail -f /var/log/user-data.log
```

### Option C: Multi-Environment Deployment (dev/staging/prod)

Uses the shared `modules/` library with isolated S3 state per environment.  
See [DEPLOYMENT.md](DEPLOYMENT.md) for the complete guide.

```bash
# Quick start for dev
cd environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit: allowed_ssh_cidr = "YOUR_IP/32"

terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

---

## 8. SSH Access and Operations

### Get Connection Details (from any lesson or environment folder)

```bash
terraform output -raw bastion_public_ip
terraform output -raw backend_private_ip
terraform output -raw frontend_private_ip

# Or get the pre-formatted commands
terraform output ssh_command      # lesson 06 (direct)
terraform output ssh_bastion      # lessons 12+ and environments
terraform output ssh_backend      # lessons 12+ and environments
```

### SSH Patterns

```bash
KEY=~/sarowar-ostad-mumbai.pem
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)
FRONTEND=$(terraform output -raw frontend_private_ip)

# Connect to bastion directly
ssh -i $KEY ubuntu@$BASTION

# Connect to backend via ProxyJump (single command, no prior bastion login)
ssh -i $KEY -J ubuntu@$BASTION ubuntu@$BACKEND

# Watch user_data script complete on backend
ssh -i $KEY -J ubuntu@$BASTION ubuntu@$BACKEND "sudo tail -f /var/log/user-data.log"
```

### Permanent SSH Config (save typing)

```
# ~/.ssh/config
Host bmi-bastion
  HostName 13.x.x.x              # update after each apply
  User ubuntu
  IdentityFile ~/sarowar-ostad-mumbai.pem
  StrictHostKeyChecking no

Host bmi-backend
  HostName 10.0.3.x              # update after each apply
  User ubuntu
  IdentityFile ~/sarowar-ostad-mumbai.pem
  ProxyJump bmi-bastion
  StrictHostKeyChecking no

Host bmi-frontend
  HostName 10.0.4.x
  User ubuntu
  IdentityFile ~/sarowar-ostad-mumbai.pem
  ProxyJump bmi-bastion
  StrictHostKeyChecking no
```

Usage: `ssh bmi-backend` — no flags needed.

### On-Instance Operational Commands

```bash
# Backend service health
pm2 status
pm2 logs bmi-backend --lines 50
pm2 restart bmi-backend

# Check the database connection string (Lessons 07+)
cat /home/ubuntu/bmi-health-tracker/backend/.env
# DATABASE_URL is fetched from Secrets Manager - never hardcoded

# Nginx (frontend or all-in-one)
sudo systemctl status nginx
sudo nginx -t                          # test config
sudo journalctl -u nginx --since "5 min ago"

# PostgreSQL (all-in-one lesson 06 only)
sudo systemctl status postgresql
sudo -u postgres psql -c "\l"

# User data progress and errors
sudo tail -100 /var/log/user-data.log
sudo cloud-init status --long
```

### SSM Session Manager (No SSH Key Required)

For lessons 10+ where `attach_ssm_policy = true` on the IAM role:

```bash
# List instances reachable via SSM
aws ssm describe-instance-information \
  --region ap-south-1 \
  --query "InstanceInformationList[].{ID:InstanceId,Name:ComputerName,Ping:PingStatus}" \
  --output table

# Connect without port 22 open, without key files
aws ssm start-session \
  --target i-0xxxxxxxxxxxxxxxx \
  --region ap-south-1
```

This is the production-preferred access pattern. No bastion host, no port 22 required.

---

## 9. Secrets and Credentials

### Design Principle

Zero passwords exist in code, Terraform state outputs, instance `.env` files at build time, or boot logs. The credential flow is:

```
Terraform apply
    |
    v
modules/secrets:
  random_password (16 chars, shell-safe special chars, never in state output)
    |
    v
AWS Secrets Manager secrets (at-rest encrypted, IAM access-controlled):
  bmi-health-tracker-<env>-db-password
  bmi-health-tracker-<env>-database-url
    |
    v (at EC2 first boot)
backend.sh (user_data): aws secretsmanager get-secret-value
  -- requires: EC2 IAM instance profile with scoped GetSecretValue permission
  -- writes: /home/ubuntu/bmi-health-tracker/backend/.env (chmod 600)
    |
    v
Node.js backend: process.env.DATABASE_URL
    |
    v
RDS PostgreSQL: authenticated connection
```

The database password is never:
- Visible in `terraform output`
- Stored as a variable in `.tfvars`
- Printed in `/var/log/user-data.log`
- Hardcoded anywhere in the codebase

### Retrieve Credentials for Debugging

```bash
# DB password (if you need to connect to RDS directly from bastion)
aws secretsmanager get-secret-value \
  --secret-id "bmi-health-tracker-dev-db-password" \
  --region ap-south-1 \
  --query SecretString \
  --output text

# Full DATABASE_URL (postgres://user:pass@host:5432/db)
aws secretsmanager get-secret-value \
  --secret-id "bmi-health-tracker-dev-database-url" \
  --region ap-south-1 \
  --query SecretString \
  --output text
```

Replace `dev` with `staging` or `prod` for other environments.

### IAM Policy (Least Privilege)

The backend EC2 role policy scopes secret access to its own project and environment:

```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret"
  ],
  "Resource": "arn:aws:secretsmanager:ap-south-1:<account>:secret:bmi-health-tracker-<env>-*"
}
```

The account ID is sourced at plan time via `data "aws_caller_identity"`. No wildcard on resources. A compromised backend instance in `dev` cannot read `prod` secrets.

---

## 10. Module Reference

Each module in `modules/` follows the same structure: `main.tf`, `variables.tf`, `outputs.tf`. All modules are consumed via `source = "../../modules/<name>"` from environment configs, and via `source = "./modules/<name>"` from lesson folders (private copies).

### `modules/vpc`

**Creates:** 1 VPC, 6 subnets (2 per tier), 1 IGW, 1 EIP, 1 NAT Gateway, 3 route tables, 6 route table associations — 19 AWS resources total.

**Key design:** Private-DB route table has no `0.0.0.0/0` route. RDS is network-isolated from the internet independent of any security group configuration.

**Key inputs:** `project_name`, `environment`, `vpc_cidr` (default `10.0.0.0/16`)
**Key outputs:** `vpc_id`, `public_subnet_ids`, `private_app_subnet_ids`, `private_db_subnet_ids`, `nat_gateway_public_ip`

### `modules/security-group`

**Creates:** 5 security groups: ALB, bastion, frontend, backend, RDS.

**Key design:** `frontend_public_access` boolean controls Phase 1 vs Phase 2 behaviour using `count` on conditional rules — one variable, no duplicated module definitions.

**Key input:** `frontend_public_access` (`false` = ALB-only access to frontend, `true` = direct internet access)
**Key outputs:** `alb_sg_id`, `bastion_sg_id`, `frontend_sg_id`, `backend_sg_id`, `rds_sg_id`

### `modules/ec2`

**Creates:** 1 EC2 instance using `data "aws_ami"` for the latest Ubuntu 22.04 LTS (Canonical owner `099720109477`). gp3 root volume, `encrypted = true`. `lifecycle { create_before_destroy = true }`.

**Key design:** Never hardcodes AMI IDs — data source resolves the latest patched AMI at plan time. The module is generic — the `role`, `iam_instance_profile`, and `user_data` variables make it serve as bastion, backend, or frontend without modification.

**Key inputs:** `name` (required), `subnet_id` (required), `security_group_ids` (required), `instance_type` (default `t3.micro`), `root_volume_size` (default `20`), `user_data` (optional), `iam_instance_profile` (optional, default `null`)
**Key outputs:** `instance_id`, `public_ip`, `private_ip`, `availability_zone`, `ami_id`

### `modules/rds`

**Creates:** 1 DB subnet group (spanning private-db subnets), 1 custom parameter group, 1 RDS Postgres 14 instance.

**Key design:** Always `storage_encrypted = true`, always `publicly_accessible = false`, Performance Insights enabled at 7 days (free tier). Password is never an output — always retrieved via Secrets Manager.

**Key inputs:** `subnet_ids` (required, list), `security_group_id` (required), `db_password` (required, sensitive), `instance_class`, `multi_az`, `backup_retention_days`, `skip_final_snapshot`, `deletion_protection`

**Key outputs:** `db_endpoint`, `db_host`, `db_port`, `db_name`, `db_username` — **no password output**

### `modules/secrets`

**Creates:** 1 `random_password` resource + 2 Secrets Manager secrets.

**Key design:** `recovery_window_days = 0` enables immediate deletion on `terraform destroy`. Without this, re-applying after destroy fails because the secret path is "pending deletion" for 7-30 days by default. `lifecycle { ignore_changes = [secret_string] }` prevents re-apply from generating a new password and breaking the running application.

**Key inputs:** `db_host` (from `module.rds.db_host`), `recovery_window_days` (default `0`)
**Key outputs:** `db_password` (sensitive, used as `module.rds.db_password`), `database_url_secret_name` (passed to `templatefile()`)

### `modules/iam`

**Creates:** 1 IAM role with EC2 assume-role trust, 1 instance profile, 1 inline Secrets Manager policy scoped to the account ARN via `data.aws_caller_identity`.

**Key inputs:** `role_suffix` (default `"backend"`), `attach_ssm_policy` (default `true`), `attach_cloudwatch_policy` (default `false`)
**Key output:** `instance_profile_name` — passed to `module.backend.iam_instance_profile`

### `modules/alb`

**Creates:** 1 internet-facing ALB, 2 target groups (frontend :80, backend :3000), HTTP:80 listener with 301 redirect, HTTPS:443 listener with TLS policy, 2 listener rules (path-based), health checks, 1 Route53 A alias record.

**Key design:** TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` disables TLS 1.0/1.1. Path rules: `/api/*` and `/health` route to backend, everything else (`/*` default) routes to frontend. Both target groups run health checks independently.

**Key inputs:** `certificate_arn`, `hosted_zone_id`, `domain_name`, `frontend_instance_ids` (list), `backend_instance_ids` (list)
**Key output:** `app_url`, `alb_dns_name`

---

## 11. Making Changes Safely

### The Golden Rule: Always Plan Before Apply

```bash
terraform plan    # review EVERY proposed change before it touches AWS
```

Look for:
- `+` — new resource (safe to add)
- `~` — in-place update (usually safe, no recreation)
- `-/+` — **replacement** (destroy + re-create — causes downtime for EC2 and RDS)
- `-` — deletion (destructive)

### Common In-Place Changes (No Recreation)

```bash
# Update your SSH CIDR (most common)
# Edit terraform.tfvars: allowed_ssh_cidr = "NEW_IP/32"
terraform plan    # shows: ~ aws_security_group_rule (in-place, ~5 seconds)
terraform apply

# Update instance tags / environment tags
# Edit terraform.tfvars: environment = "staging"
terraform plan    # shows: ~ tags only, no recreation

# Scale RDS (triggers maintenance window, not immediate)
# Edit: instance_class = "db.t3.small"
terraform plan    # shows: ~ aws_db_instance.main
terraform apply   # applies during next maintenance window unless apply_immediately = true
```

### Changes That Force Instance Replacement

These show as `-/+` in plan:

| Change | Cause | Impact |
|---|---|---|
| `user_data` content | Immutable on running instance | New instance, new public IP, fresh bootstrap |
| `ami` (new `data "aws_ami"` result) | AMI is launch-time only | New instance |
| `subnet_id` | Subnet is launch-time only | New instance |

With `lifecycle { create_before_destroy = true }` (set in `modules/ec2`), new instance launches before old one terminates, minimising downtime.

### Format Before Every Commit

```bash
terraform fmt -recursive .         # auto-format all .tf files
terraform fmt -check               # non-zero exit if formatting differs (use in CI)
```

### Validate Configuration Without Deploying

```bash
# Single lesson
cd 05-networking-vpc
terraform init -backend=false      # init without connecting to S3
terraform validate                 # check HCL syntax and schema

# All environments
for env in dev staging prod; do
  cd environments/$env
  terraform init -backend=false > /dev/null
  terraform validate && echo "$env: OK"
  cd ../..
done
```

### State Operations

```bash
# See all resources Terraform is tracking
terraform state list

# Inspect a specific resource's full attributes
terraform state show module.vpc.aws_nat_gateway.main

# Remove a resource from state without destroying it (use sparingly)
terraform state rm aws_instance.old_server

# Import an existing AWS resource into state
terraform import aws_security_group.imported sg-0xxxxxxxxxxxxxxxxx

# Backup remote state before risky changes
terraform state pull > backup-$(date +%Y%m%d).tfstate
```

---

## 12. Cost and Cleanup

### Estimated Cost — Production (per hour)

| Resource | Config | $/hour |
|---|---|---|
| Backend EC2 | t3.large | $0.083 |
| Frontend EC2 | t3.medium | $0.042 |
| Bastion EC2 | t3.micro | $0.010 |
| RDS PostgreSQL | db.t3.medium, Multi-AZ | $0.136 |
| NAT Gateway | running | $0.045 |
| Application Load Balancer | per hour | $0.008 |
| **Total** | | **~$0.32/hour** |

A typical 2-hour class: **~$0.65**. Forgetting to destroy for 24 hours: **~$7.70**.

### Estimated Cost — Single Instance (Lesson 06)

| Resource | Config | $/hour |
|---|---|---|
| EC2 | t3.small | $0.023 |
| NAT Gateway | none (default VPC) | $0 |
| **Total** | | **~$0.023/hour** |

### Destroy After Every Session

```bash
# From a lesson folder
terraform destroy -auto-approve

# Verify complete
terraform state list
# Expected: empty output

# From an environment folder
cd environments/dev
terraform destroy -auto-approve

# Check no resources remain
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Project,Values=bmi-health-tracker" \
            "Name=instance-state-name,Values=running,stopped,pending" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected: empty

# Check NAT Gateways (most expensive if left running)
aws ec2 describe-nat-gateways \
  --region ap-south-1 \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].NatGatewayId" \
  --output text
# Expected: empty
```

### Do NOT Destroy Bootstrap Resources

`03-state-management/bootstrap` creates the S3 bucket and DynamoDB table. These store remote state for ALL `environments/`. Destroying them makes all environment infrastructure permanently unmanageable by Terraform.

**Only destroy bootstrap when you are completely done with this repository.**

```bash
# Safe order for final teardown of everything:
# 1. Destroy each environment first
cd environments/dev     && terraform destroy -auto-approve
cd environments/staging && terraform destroy -auto-approve
cd environments/prod    && terraform destroy -auto-approve

# 2. Only then destroy bootstrap
cd 03-state-management/bootstrap && terraform destroy -auto-approve
```

---

## 13. Troubleshooting

### App Not Responding After Apply

`terraform apply` finishes in ~1 minute but `user_data` runs in the background for 3-5 more minutes. The app is not ready until user_data completes.

```bash
# Wait and retry
PUBLIC_IP=$(terraform output -raw public_ip)
while ! curl -sf "http://$PUBLIC_IP/health" > /dev/null 2>&1; do
  echo "Waiting..."; sleep 15
done
echo "Ready."

# OR: SSH in and watch live
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$PUBLIC_IP
sudo tail -f /var/log/user-data.log
```

If the script is complete but the app still does not respond, check:
```bash
pm2 status            # is the backend process running?
pm2 logs --lines 30   # what errors occurred?
sudo systemctl status nginx
curl http://127.0.0.1:3000/health   # does backend respond locally?
```

### 502 Bad Gateway from ALB

The ALB health checks are failing — the backend or frontend is not healthy.

```bash
# Check target health across both target groups
aws elbv2 describe-target-groups \
  --region ap-south-1 \
  --query "TargetGroups[?contains(TargetGroupName,'bmi')].TargetGroupArn" \
  --output text | tr '\t' '\n' | while read ARN; do
    echo "--- $ARN ---"
    aws elbv2 describe-target-health --target-group-arn "$ARN" \
      --query "TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
      --output table
done
```

Common causes: `user_data` still running (wait and retry), PM2 crashed, wrong port in target group.

### SSH: Connection Timed Out

Your current IP does not match `allowed_ssh_cidr`.

```bash
MY_IP=$(curl -s ifconfig.me)
echo "My IP: $MY_IP"
# Update terraform.tfvars: allowed_ssh_cidr = "$MY_IP/32"
terraform apply   # updates security group in ~5 seconds
```

### SSH: Permission Denied (publickey)

Wrong key file or wrong username. Ubuntu 22.04 AMI default user is always `ubuntu`:

```bash
# Correct form:
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@<PUBLIC_IP>
#         ^--- correct path         ^--- must be 'ubuntu', not 'ec2-user' or 'admin'
```

### terraform apply Fails Mid-Run

Terraform is idempotent — re-run after fixing the error:

```bash
terraform apply    # creates only what is missing, skips what already exists
```

If a specific resource is stuck, target it:
```bash
terraform apply -target=module.rds.aws_db_instance.main
```

### NAT Gateway Stuck in Deleting (terraform destroy hangs)

NAT Gateway deletion takes 60-90 seconds. Terraform waits for it. Do not interrupt.

If it genuinely times out:
```bash
aws ec2 describe-nat-gateways \
  --region ap-south-1 \
  --query "NatGateways[?State!='deleted'].{ID:NatGatewayId,State:State}" \
  --output table
# Once state = deleted, re-run: terraform destroy
```

### Secrets Manager Re-Apply Error

```
Error creating Secret: ResourceExistsException: A resource with the ID already exists
```

A previous `terraform destroy` left the secret in "pending deletion" state (7+ day default window).

**Fix:** The `modules/secrets` module sets `recovery_window_days = 0` to prevent this. If you encounter it, the secret was created outside of this module. Force-delete it:
```bash
aws secretsmanager delete-secret \
  --secret-id "bmi-health-tracker-dev-database-url" \
  --force-delete-without-recovery \
  --region ap-south-1
```

---

## 14. Key Design Decisions

### Why `deletion_protection = false` on RDS?

Teaching repository — `terraform destroy` must complete cleanly after class without manual AWS Console intervention. In real production, always set `deletion_protection = true` and require a manual change + plan approval before deletion.

### Why `recovery_window_days = 0` on Secrets Manager?

The default 7-day recovery window causes `terraform apply` to fail on a second attempt after destroy because the secret ARN is still "pending deletion". Setting to `0` allows clean destroy/re-apply cycles. In production, use 7-30 days for accidental deletion protection.

### Why `skip_final_snapshot = true` on RDS?

Removes the need to manually delete an orphaned snapshot after every destroy. In production, set `skip_final_snapshot = false` and `final_snapshot_identifier = "bmi-prod-final-$(date +%Y%m%d)"`.

### Why modules are copied into each lesson folder

Each lesson folder must work entirely in isolation — no dependency on anything outside it. A student doing only Lesson 06 should not need to understand the root `modules/` library. The root `modules/` directory is the source of truth for content. Changes to root modules must be manually propagated to the lesson copies that use them.

### Why `lifecycle { ignore_changes = [secret_string] }` on Secrets Manager

Without this, every `terraform apply` would regenerate the password (a new `random_password` result) and update the secret — silently breaking the running application whose `.env` file still holds the old connection string. The `ignore_changes` means Terraform creates the secret once and never modifies its value.

### Why `create_before_destroy = true` on EC2

When `user_data` changes, Terraform must replace the instance. Without this lifecycle rule the sequence is: destroy -> launch -> downtime. With it: launch -> wait for healthy -> destroy -> minimal downtime. For instances behind an ALB, the new instance is registered and passing health checks before the old one is deregistered.

### Why two Availability Zones for everything

The Application Load Balancer requires registered targets in at least two AZs. RDS Multi-AZ requires a DB subnet group spanning at least two AZs. Building both AZs from the start (Lesson 05 onwards) means no rework is needed when ALB and Multi-AZ RDS are introduced in later lessons.

### Why the Private-DB route table has no internet route

Defense-in-depth. Even if all security group rules on the RDS instance were misconfigured to allow all traffic, the absence of a `0.0.0.0/0` route in the private-db route table means the database cannot send or receive internet traffic at the network layer. Security groups and route tables are independent controls.

### Why `frontend_public_access` is a single boolean, not two separate modules

Duplicating the security-group module for Phase 1 and Phase 2 would create a maintenance burden — any update to the SG rules would need to be applied twice. A single `count`-based conditional resource in the module handles both phases with one line of change in `terraform.tfvars`. This demonstrates idiomatic Terraform conditional resource patterns.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
