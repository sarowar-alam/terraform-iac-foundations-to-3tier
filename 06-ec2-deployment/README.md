# 06 - EC2 Deployment

> **Course Position:** Lesson 06 of 13 - Module 7, Section 6: Single-Instance Full Stack Deployment
> **Objective:** Automate everything done manually in Module 4 (40+ shell commands) into a single `terraform apply`. One EC2 instance runs all three application tiers: PostgreSQL 14 database, Node.js 18 backend API, and a Nginx-served React frontend.

This lesson bridges Module 4 (manual server provisioning) and Module 7 (Terraform infrastructure-as-code). The same result - a fully working BMI Health Tracker - is now reproducible in minutes from a single command, without touching a terminal after `terraform apply`.

**Prerequisites:** Lessons 01-05 completed. A key pair named `sarowar-ostad-mumbai` must already exist in `ap-south-1`. Your current public IP is required for SSH access.

---

## Table of Contents

1. [What This Lesson Does](#1-what-this-lesson-does)
2. [Technology Stack](#2-technology-stack)
3. [Architecture](#3-architecture)
4. [Folder Structure and File Reference](#4-folder-structure-and-file-reference)
5. [Prerequisites](#5-prerequisites)
6. [Step-by-Step Deployment](#6-step-by-step-deployment)
7. [Verifying the Deployment](#7-verifying-the-deployment)
8. [Understanding the Code](#8-understanding-the-code)
9. [Making Changes Safely](#9-making-changes-safely)
10. [Cleanup](#10-cleanup)
11. [Key Concepts and Design Decisions](#11-key-concepts-and-design-decisions)
12. [Common Errors and Fixes](#12-common-errors-and-fixes)
13. [What Comes Next](#13-what-comes-next)

---

## 1. What This Lesson Does

Module 4 required executing 40+ shell commands manually to set up one server. This lesson replaces that entire workflow with Terraform and a single bootstrap script.

| Module 4 (Manual) | Module 7 Lesson 06 (Terraform) |
|---|---|
| `ssh` into server manually | `terraform apply` handles everything |
| `apt-get install` for each package | `single-instance.sh` user_data script |
| Hand-write Nginx config | Script writes config from template |
| Set environment variables manually | Script generates `.env` automatically |
| Run migrations one by one | Script loops all `*.sql` files sorted |
| PM2 start command | Script starts PM2 with ecosystem config |
| 40+ commands, 30+ minutes | 1 command, ~5 minutes (plus 3 min boot) |

**What is created (2 managed AWS resources):**

| Resource | Type | Purpose |
|---|---|---|
| `aws_security_group.single_instance` | AWS Security Group | Firewall: SSH from your IP, HTTP/HTTPS from everywhere |
| `module.single_instance` (`aws_instance.this`) | EC2 t3.small Ubuntu 22.04 | All three application tiers in one box |

**Data sources (read-only, nothing created):**

| Data Source | What It Reads |
|---|---|
| `data.aws_vpc.default` | Default VPC ID in ap-south-1 |
| `data.aws_subnets.default` | Subnet IDs inside the default VPC |
| `data.aws_ami.ubuntu` (in module) | Latest Ubuntu 22.04 LTS AMI ID |

**New Terraform patterns introduced:**

| Pattern | Where |
|---|---|
| `data "aws_vpc"` - lookup existing infrastructure | `main.tf` line 34 |
| `data "aws_subnets"` with `filter` block | `main.tf` line 87 |
| `tolist()` built-in function | `main.tf` - `tolist(data.aws_subnets.default.ids)[0]` |
| `file()` function - load external file | `main.tf` - `user_data = file("${path.module}/scripts/...")` |
| `lifecycle { create_before_destroy = true }` | `modules/ec2/main.tf` |
| `data "aws_ami"` with multiple filters | `modules/ec2/main.tf` |
| Module variable `iam_instance_profile = null` | `modules/ec2/variables.tf` - optional hook |
| `encrypted = true` on root EBS | `modules/ec2/main.tf` - security default |

---

## 2. Technology Stack

### Application Tiers (all on one EC2)

| Tier | Technology | Version | Port | Listens On |
|---|---|---|---|---|
| Database | PostgreSQL | 14 | 5432 | 127.0.0.1 (local only) |
| Backend API | Node.js + Express + PM2 | Node 18 LTS | 3000 | 127.0.0.1 (local only) |
| Frontend | React 18 (Vite build) + Nginx | Nginx 1.18+ | 80 | 0.0.0.0 (public) |

### Infrastructure Tools

| Tool | Version | Role |
|---|---|---|
| Terraform | >= 1.5.0 | Infrastructure provisioning |
| AWS Provider | ~> 5.0 | AWS API calls |
| Ubuntu | 22.04 LTS (Jammy) | EC2 operating system |
| EC2 | t3.small (2 vCPU, 2 GB RAM) | Compute host |
| EBS | gp3, 30 GB, encrypted | Storage |

### Why t3.small for This Lesson?

PostgreSQL, Node.js, and a Vite React build all run concurrently on the same machine. `t3.micro` (1 GB RAM) runs out of memory during the `npm run build` step. `t3.small` provides 2 GB, which is sufficient for this development use case.

For production, each tier moves to a dedicated resource (RDS, EC2 backend fleet, separate frontend). That separation happens in Lessons 07-09.

---

## 3. Architecture

### Single-Instance Layout

```
INTERNET  (TCP 80/443 0.0.0.0/0)
    |
    v
AWS Default VPC (172.31.0.0/16)
    |
    +-- Security Group: bmi-health-tracker-dev-single-sg
    |     Inbound:  22/tcp  <- YOUR_IP/32 only
    |               80/tcp  <- 0.0.0.0/0
    |              443/tcp  <- 0.0.0.0/0
    |     Outbound:  all    -> 0.0.0.0/0
    |
    v
EC2: bmi-health-tracker-dev-single-instance
     Ubuntu 22.04 LTS, t3.small
     Public IP: <auto-assigned from default VPC>
     AZ: ap-south-1a (first subnet of default VPC)
     EBS: gp3 30GB encrypted root volume
     |
     +-- Nginx (port 80) -----> serves /var/www/html/ (React SPA)
     |         |  /api/*        proxy_pass to 127.0.0.1:3000
     |         |  /health       proxy_pass to 127.0.0.1:3000/health
     |
     +-- Node.js + PM2 (port 3000, localhost only)
     |         |  ecosystem.config.js --env production
     |         |  /home/ubuntu/bmi-health-tracker/backend/
     |
     +-- PostgreSQL 14 (port 5432, 127.0.0.1 only)
               database: bmidb
               user:     bmi_user
               password: <random, generated at boot>
```

### Request Flow

```
Browser -> EC2:80 -> Nginx
                         |
                         +-- /api/*  -------> Node.js:3000 -> PostgreSQL:5432
                         |
                         +-- / (all others) -> /var/www/html/index.html (React SPA)
```

All inter-tier communication is loopback (`127.0.0.1`). PostgreSQL and Node.js are never directly reachable from the internet - Nginx is the sole public entry point.

### Default VPC vs Custom VPC

This lesson deliberately uses the AWS Default VPC, not the custom VPC built in Lesson 05.

| | Default VPC | Custom VPC (Lesson 05) |
|---|---|---|
| Created by | AWS, always present | Lesson 05 Terraform |
| Subnets | Public only, one per AZ | Public + Private-App + Private-DB |
| Use case | Development, learning | Production 3-tier apps |
| This lesson | Yes - simplest possible setup | Lessons 07-13 |

The comment in `main.tf` is explicit: "Default VPC - no custom VPC needed for Module 4 single-instance." Moving to the custom VPC happens in Lesson 08.

---

## 4. Folder Structure and File Reference

```
06-ec2-deployment/
|-- main.tf                     Provider, data sources, security group, module call
|-- variables.tf                6 variables (1 required: allowed_ssh_cidr)
|-- outputs.tf                  6 outputs incl. app_url, ssh_command, check_logs
|-- terraform.tfvars.example    Pre-filled example (set allowed_ssh_cidr before apply)
|-- README.md                   This file
|
+-- scripts/
|   +-- single-instance.sh      Full three-tier bootstrap (runs as EC2 user_data)
|
+-- modules/
    +-- ec2/
        |-- main.tf             EC2 instance + AMI data source + lifecycle
        |-- variables.tf        8 variables (name, subnet_id, security_group_ids required)
        +-- outputs.tf          5 outputs: instance_id, private_ip, public_ip, az, ami_id

|-- (auto-generated after init/apply)
|-- .terraform/                 Provider binaries + module symlink
|-- .terraform.lock.hcl         Provider version lock
+-- terraform.tfstate           Local state (2 resources)
```

### Root `main.tf` - Annotated

```hcl
# Lookup default VPC - no resource created
data "aws_vpc" "default" {
  default = true
}

# Lookup all subnets in default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group defined at root (not in module) - varies per deployment
resource "aws_security_group" "single_instance" {
  vpc_id = data.aws_vpc.default.id   # attached to default VPC
  ...
  ingress { from_port = 22, cidr_blocks = [var.allowed_ssh_cidr] }  # SSH: your IP only
  ingress { from_port = 80, cidr_blocks = ["0.0.0.0/0"] }           # HTTP: public
  ingress { from_port = 443, cidr_blocks = ["0.0.0.0/0"] }          # HTTPS: public
  egress  { protocol = "-1", cidr_blocks = ["0.0.0.0/0"] }          # all outbound
}

# Module call - passes security group ID in, gets public_ip out
module "single_instance" {
  source             = "./modules/ec2"
  name               = "${var.project_name}-${var.environment}-single-instance"
  role               = "all-tiers"                   # descriptive tag
  instance_type      = var.instance_type             # t3.small
  subnet_id          = tolist(data.aws_subnets.default.ids)[0]   # first default subnet
  security_group_ids = [aws_security_group.single_instance.id]
  key_name           = var.key_name
  root_volume_size   = 30                            # 30 GB for all three tiers
  user_data          = file("${path.module}/scripts/single-instance.sh")
}
```

### Root `variables.tf`

| Variable | Type | Default | Required? | Notes |
|---|---|---|---|---|
| `aws_region` | string | `"ap-south-1"` | No | Mumbai |
| `project_name` | string | `"bmi-health-tracker"` | No | Used in resource names |
| `environment` | string | `"dev"` | No | Used in resource names and tags |
| `instance_type` | string | `"t3.small"` | No | See sizing note above |
| `key_name` | string | `"sarowar-ostad-mumbai"` | No | Must exist in ap-south-1 |
| `allowed_ssh_cidr` | string | **none** | **Yes** | Your IP as `x.x.x.x/32` |

`allowed_ssh_cidr` is the only required variable. Terraform will prompt for it interactively if not set in `terraform.tfvars`.

### Root `outputs.tf`

| Output | Value | Usage |
|---|---|---|
| `instance_id` | EC2 instance ID | AWS CLI commands, state inspection |
| `public_ip` | Instance public IPv4 | Browser access, SSH |
| `app_url` | `http://<public_ip>` | Open in browser after 3 min wait |
| `health_check_url` | `http://<public_ip>/health` | curl-able health endpoint |
| `ssh_command` | Full `ssh -i ...` command | Paste directly into terminal |
| `check_logs` | Log tail command | Monitor bootstrap progress |

### `scripts/single-instance.sh`

The complete three-tier bootstrap. Runs as EC2 `user_data` on first boot - **executes once only**. Key behaviours:

- `set -euo pipefail` - exits immediately on any error
- All output tee'd to `/var/log/user-data.log` and system log
- Random DB password: `openssl rand -base64 16 | tr -d '/+='` (no Secrets Manager yet)
- Public IP fetched from EC2 Instance Metadata Service: `http://169.254.169.254/latest/meta-data/public-ipv4`
- App cloned from GitHub at boot: `github.com/md-sarowar-alam/terraform-iac-foundations-to-3tier.git`
- Migrations run in sorted order: `ls migrations/*.sql | sort | psql ...`
- PM2 configured for systemd restart on reboot

### `modules/ec2/main.tf`

The generic, reusable EC2 module. Used by this lesson as "all-tiers" and reused in Lessons 08, 09, 12 for individual frontend/backend/bastion roles.

**AMI selection - never hardcode AMI IDs:**
```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's official AWS account ID

  filter { name = "name",               values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "virtualization-type", values = ["hvm"] }
  filter { name = "state",              values = ["available"] }
}
```

`099720109477` is Canonical's canonical (pun intended) AWS account ID. Filtering by this owner prevents using community AMIs that could be trojaned. The `name` filter pins the Ubuntu version to 22.04 Jammy while always getting the latest patch release.

**EBS volume - security defaults:**
```hcl
root_block_device {
  volume_type           = "gp3"          # current generation, better IOPS than gp2
  volume_size           = var.root_volume_size
  delete_on_termination = true           # no orphaned volumes after destroy
  encrypted             = true           # AES-256 at rest (AWS-managed key)
}
```

`encrypted = true` uses the AWS-managed EBS default key. No KMS charges. Satisfies data-at-rest compliance requirements in most frameworks.

**Lifecycle policy:**
```hcl
lifecycle {
  create_before_destroy = true
}
```

When `user_data` changes (e.g., updated script), Terraform replaces the instance. With `create_before_destroy`, the new instance is fully launched before the old one is terminated. This reduces downtime from the replacement sequence.

---

## 5. Prerequisites

### Tools

```bash
terraform version    # >= 1.5.0 required
aws sts get-caller-identity --region ap-south-1   # must succeed
```

### AWS Key Pair

The `key_name` variable defaults to `sarowar-ostad-mumbai`. This key pair must exist in `ap-south-1` **before** running `terraform apply`. Terraform does not create it - it only references the name.

Verify it exists:
```bash
aws ec2 describe-key-pairs \
  --key-names sarowar-ostad-mumbai \
  --region ap-south-1 \
  --query "KeyPairs[0].KeyName" \
  --output text
# Expected: sarowar-ostad-mumbai
```

The private key file (`sarowar-ostad-mumbai.pem`) must be present locally for SSH:
```bash
ls -la sarowar-ostad-mumbai.pem
chmod 400 sarowar-ostad-mumbai.pem   # AWS requires 400 permissions
```

### Your Current Public IP

`allowed_ssh_cidr` must be your current public IP in CIDR notation:

```bash
# Get your current public IP
curl -s ifconfig.me
# Returns: 203.0.113.45  ->  use as: 203.0.113.45/32
```

If you are on a corporate VPN or dynamic IP, this will change when you reconnect. You will need to re-apply with the new IP to restore SSH access.

### IAM Permissions Required

Minimal permissions needed:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeImages",
    "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
    "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
    "ec2:DescribeSecurityGroups",
    "ec2:RunInstances", "ec2:TerminateInstances",
    "ec2:DescribeInstances", "ec2:DescribeInstanceAttribute",
    "ec2:CreateTags", "ec2:DescribeTags"
  ],
  "Resource": "*"
}
```

`AdministratorAccess` covers all of the above.

### Cost

| Resource | Hourly Cost | Daily Cost |
|---|---|---|
| t3.small EC2 | ~$0.023/hr | ~$0.55 |
| gp3 EBS (30 GB) | ~$0.003/hr | ~$0.07 |
| **Total** | ~$0.026/hr | **~$0.62/day** |

This is a development instance. **Destroy after the lesson.**

---

## 6. Step-by-Step Deployment

### Step 1: Navigate to This Folder

```bash
cd 06-ec2-deployment
```

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Get your public IP and edit the file:
```bash
MY_IP=$(curl -s ifconfig.me)
echo "Your IP: $MY_IP"
```

Edit `terraform.tfvars`:
```hcl
aws_region       = "ap-south-1"
project_name     = "bmi-health-tracker"
environment      = "dev"
instance_type    = "t3.small"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "203.0.113.45/32"   # replace with your actual IP
```

### Step 3: Initialize

```bash
terraform init
```

Expected output includes:
```
Initializing modules...
- single_instance in modules/ec2

Terraform has been successfully initialized!
```

### Step 4: Plan

```bash
terraform plan
```

Expected:
```
Plan: 2 to add, 0 to change, 0 to destroy.
```

Confirm the plan shows:
- `aws_security_group.single_instance` with your IP in the SSH ingress rule
- `module.single_instance.aws_instance.this` - t3.small, Ubuntu AMI, 30 GB gp3

The `data` sources are not listed in the "to add" count. Data sources are always read during plan.

### Step 5: Apply

```bash
terraform apply
```

Type `yes`. Apply completes in under 1 minute. The EC2 instance will be `running` immediately, but the application setup continues in the background via `user_data`.

Expected output:
```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

app_url          = "http://13.x.x.x"
check_logs       = "sudo tail -f /var/log/user-data.log"
health_check_url = "http://13.x.x.x/health"
instance_id      = "i-0xxxxxxxxxxxxxxxx"
public_ip        = "13.x.x.x"
ssh_command      = "ssh -i sarowar-ostad-mumbai.pem ubuntu@13.x.x.x"
```

### Step 6: Wait for Bootstrap to Complete

The `user_data` script takes approximately 3-5 minutes. It installs packages, clones the repo, builds React, and starts all services.

Monitor progress:
```bash
# Copy the ssh_command from the output
ssh -i sarowar-ostad-mumbai.pem ubuntu@<public_ip>

# Once SSH'd in:
sudo tail -f /var/log/user-data.log
```

The script is complete when you see:
```
======================================
 Setup complete!
 Application URL : http://<public_ip>
 Backend health  : http://<public_ip>/health
 Backend port    : 3000 (local)
 Database        : bmidb @ 127.0.0.1:5432
======================================
```

Alternatively, poll the health endpoint:
```bash
PUBLIC_IP=$(terraform output -raw public_ip)
while ! curl -sf "http://$PUBLIC_IP/health" > /dev/null 2>&1; do
  echo "Waiting for health check..."; sleep 10
done
echo "Application is up!"
```

---

## 7. Verifying the Deployment

### Confirm Health Endpoint

```bash
PUBLIC_IP=$(terraform output -raw public_ip)
curl -s "http://$PUBLIC_IP/health" | python3 -m json.tool
```

Expected:
```json
{
  "status": "ok",
  "timestamp": "2026-04-12T...",
  "database": "connected"
}
```

If `"database": "connected"` - all three tiers are working end-to-end.

### Confirm the Application in Browser

Open `terraform output -raw app_url` in a browser. You should see the BMI Health Tracker form. Add a measurement - it will be saved to PostgreSQL via the Node.js API.

### SSH and Inspect Services

```bash
ssh -i sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
```

Once connected:

```bash
# Check Node.js backend (PM2)
pm2 status
# Expected: bmi-health-tracker  online

# Check PostgreSQL
systemctl status postgresql
# Expected: active (running)

# Check Nginx
systemctl status nginx
# Expected: active (running)

# Check backend .env file
cat /home/ubuntu/bmi-health-tracker/backend/.env
# Expected: NODE_ENV=production, PORT=3000, DATABASE_URL=..., FRONTEND_URL=...

# Test backend directly (bypassing Nginx)
curl http://127.0.0.1:3000/health
# Expected: {"status":"ok",...}

# Check open ports
ss -tlnp | grep -E '(80|3000|5432)'
# Expected: 80 -> nginx, 3000 -> node, 5432 -> postgres (on 127.0.0.1)
```

### Confirm Security Group Restrictions

PostgreSQL and Node.js must NOT be reachable from the internet:

```bash
# From your laptop (NOT from inside the EC2):
PUBLIC_IP=$(terraform output -raw public_ip)

# This should FAIL (timeout) - PostgreSQL not exposed
nc -zv -w 3 $PUBLIC_IP 5432; echo "Exit: $?"

# This should FAIL (timeout) - Node.js not exposed
nc -zv -w 3 $PUBLIC_IP 3000; echo "Exit: $?"

# This should SUCCEED - Nginx on port 80 is exposed
curl -sf "http://$PUBLIC_IP/" > /dev/null; echo "HTTP Exit: $?"
```

### Confirm State

```bash
terraform state list
# module.single_instance.data.aws_ami.ubuntu
# module.single_instance.aws_instance.this
# aws_security_group.single_instance

terraform state show module.single_instance.aws_instance.this
# Shows all instance attributes including ami, instance_type, subnet_id, tags
```

---

## 8. Understanding the Code

### `data "aws_vpc" "default"` - Reading Existing Infrastructure

```hcl
data "aws_vpc" "default" {
  default = true
}
```

Data sources are read-only. This does not create a VPC - it reads the ID of the default VPC that AWS provides in every region. The result (`data.aws_vpc.default.id`) is used as the VPC for the security group.

Data sources run during the `plan` phase. If the default VPC has been deleted from this account, this data source fails and the plan is rejected.

### `data "aws_subnets"` with `filter` - Dynamic Lookup

```hcl
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
```

`data "aws_subnets"` returns a list of all subnet IDs matching the filter. Chaining filters is how Terraform queries AWS without hardcoding IDs. The result `data.aws_subnets.default.ids` is a `set(string)`.

`tolist(data.aws_subnets.default.ids)[0]` converts the set to an ordered list and takes the first element. This is an arbitrary choice for development - in production, a specific AZ is chosen explicitly.

### `file()` Function - Externalizing User Data

```hcl
user_data = file("${path.module}/scripts/single-instance.sh")
```

`file()` reads a local file and returns its contents as a string. `${path.module}` resolves to the directory containing the current `.tf` file - here, `06-ec2-deployment/`. This ensures the path works regardless of where `terraform` is invoked from.

The alternative to `file()` is an inline heredoc. For scripts longer than ~10 lines, externalizing to a `.sh` file is strongly preferred because:
- The file gets syntax highlighting in editors
- The script can be tested independently before applying
- The Terraform file stays readable

### `lifecycle { create_before_destroy = true }` - Safe Replacement

```hcl
lifecycle {
  create_before_destroy = true
}
```

EC2 instances are replaced (not updated in-place) when `user_data` or the AMI changes. Without this lifecycle rule, Terraform would:
1. Terminate the old instance
2. Launch the new instance (downtime window between steps 1 and 2)

With `create_before_destroy`:
1. Launch the new instance
2. Terminate the old instance (downtime window is minimal)

For single-instance development, this barely matters. For production instances behind a load balancer, this is critical.

### `encrypted = true` on EBS - Security Default

```hcl
root_block_device {
  encrypted = true
}
```

Without this, the root EBS volume is unencrypted by default (unless the account has "Encryption by default" enabled globally). An unencrypted volume means data is readable if someone gains access to the physical disk or creates a snapshot from the AWS Console.

`encrypted = true` enables AES-256 encryption using the AWS-managed `aws/ebs` key - no cost, no KMS key to manage.

### `data "aws_ami"` - Never Hardcode AMI IDs

AMI IDs are region-specific and change with every Ubuntu patch release. Hardcoding `ami-0f58b397bc5c1f2e8` breaks the moment Canonical publishes a patch.

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's AWS account - never changes
  filter { name = "name", values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
}
```

The `name` filter pins the Ubuntu major version (22.04 Jammy) while `most_recent = true` selects the latest patch automatically. This is safe because Ubuntu 22.04 is LTS and maintains API compatibility throughout its lifecycle (until 2027).

**Important:** If you run `terraform apply` a month later, you may get a newer AMI. The output `ami_id` tells you which AMI was used. For production, pin the AMI ID in state and use `ignore_changes = [ami]` in lifecycle to prevent drift-triggered replacements.

### Why the Security Group Is Defined at Root, Not in the Module

The EC2 module accepts `security_group_ids` as an input - it does not create a security group internally. This is intentional:

- Lesson 06 (all-tiers): One SG with SSH + HTTP + HTTPS
- Lesson 08 (frontend only): SG with HTTP/HTTPS only
- Lesson 08 (backend only): SG with port 3000 from ALB only
- Lesson 12 (bastion): SG with SSH only

The same EC2 module works for all four scenarios by changing only the security group passed in. If the module created the SG, it would need to accept every possible port combination as variables - far more complex.

### How the Bootstrap Script Handles the Database Password

```bash
DB_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=')"
```

A random password is generated at boot using `openssl`. It is:
- Written to `/home/ubuntu/bmi-health-tracker/backend/.env` (permissions `600`)
- Written to PostgreSQL during `createuser` (via `psql <<PSQL` heredoc)
- Visible in `/var/log/user-data.log` (stdout of the script)

**This is a development-only approach.** The password exists in the boot log where any user with `sudo` can read it. Lessons 10+ introduce AWS Secrets Manager to handle credentials properly.

---

## 9. Making Changes Safely

### Update Your SSH CIDR (IP Changed)

```bash
# Get new IP
curl -s ifconfig.me   # e.g. 198.51.100.10

# Update terraform.tfvars
allowed_ssh_cidr = "198.51.100.10/32"

terraform apply
```

Terraform updates the security group ingress rule in-place. The EC2 instance is not touched. Completes in ~5 seconds.

### Change Instance Type

```bash
# In terraform.tfvars:
instance_type = "t3.medium"

terraform plan
```

The plan shows: `# module.single_instance.aws_instance.this will be updated in-place`. Instance type changes do not require replacement - AWS handles this.

However, the instance will be **stopped and restarted** to apply the type change. Expect ~1-2 minutes of downtime.

### Update the Bootstrap Script

```bash
# Edit scripts/single-instance.sh
# ...make changes...

terraform plan
```

The plan shows: `# module.single_instance.aws_instance.this must be replaced`. This is because `user_data` is immutable for a running instance - Terraform must create a new instance.

With `create_before_destroy = true`:
1. New instance launches (new public IP assigned)
2. Old instance terminated

**The new instance runs the updated script from scratch** - fresh PostgreSQL install, fresh git clone. Any data in the old PostgreSQL is lost.

For this reason, do not store test data in the lesson 06 instance that you need to keep.

### Force Replacement Without Code Change

```bash
# Explicitly replace the instance
terraform apply -replace="module.single_instance.aws_instance.this"
```

Use this when a user_data script change was done manually on the server and you want to re-provision from scratch.

---

## 10. Cleanup

```bash
terraform destroy
```

Type `yes`. Destroys in reverse dependency order:
1. EC2 instance (terminates, EBS volume deleted because `delete_on_termination = true`)
2. Security group

Expected:
```
Destroy complete! Resources: 2 destroyed.
```

Note: The destroy takes ~30 seconds. Security group deletion will fail if there are any ENIs still attached to it (which there won't be after the instance terminates).

Verify cleanup:
```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Project,Values=bmi-health-tracker" \
  --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId" \
  --output text
# Expected: empty
```

---

## 11. Key Concepts and Design Decisions

### Single Instance vs Three Tiers - What Changes in Later Lessons

| Concern | Lesson 06 (Single) | Lessons 08-13 (Three Tier) |
|---|---|---|
| Database | PostgreSQL on EC2, local disk | RDS PostgreSQL (managed, separate AZ) |
| Database password | Random bash variable, in .env | AWS Secrets Manager |
| Backend API | PM2 on same EC2 | Separate EC2 in private subnet |
| Frontend | React build in /var/www/html | Separate EC2 or ALB |
| Networking | Default VPC, public subnet | Custom VPC, private subnets |
| Scaling | None - single box | ALB + multiple backend instances |
| HA | None - single AZ | Multi-AZ RDS + cross-AZ ALB |

The "all on one box" approach from Module 4 is intentionally preserved here as a Terraform learning exercise. It shows that the same infrastructure can be expressed as code. The production architecture improvements are incremental across lessons 07-13.

### `set -euo pipefail` in User Data Scripts

All three flags are important for production scripts:

| Flag | Meaning | Without It |
|---|---|---|
| `-e` | Exit on any error | Script continues after a failed `apt-get` |
| `-u` | Exit on unset variable | `$UNDEFINED_VAR` silently becomes empty string |
| `-o pipefail` | Exit if any pipe component fails | `false \| true` exits 0 (success) |

Combined: if any command in the script fails, the entire script exits. The boot log (`/var/log/user-data.log`) will show exactly which command failed.

### User Data Is a One-Shot Script

`user_data` runs **once only** - on the first boot of an instance that was launched. If the script fails halfway through (e.g., GitHub is unreachable), the instance is in a partial state. Solutions:

1. **SSH in and fix manually** - useful when learning
2. **`terraform apply -replace`** - destroys and re-creates, runs fresh user_data
3. **Re-run the script manually** - `sudo bash /home/ubuntu/single-instance.sh` - but it may fail on already-created resources (e.g., PostgreSQL user already exists)

For production, AWS Systems Manager (SSM) Run Command replaces user_data for post-launch configuration. Terraform `null_resource` with `remote-exec` provisioner is another option, though AWS discourages provisioners.

### Why Not Use `templatefile()` Instead of `file()`?

Terraform offers `templatefile("path", {vars})` to inject Terraform variables into a script at plan time:
```hcl
user_data = templatefile("${path.module}/scripts/setup.sh", {
  db_password = random_password.db.result
})
```

This lesson uses `file()` (no variable injection) because the database password is generated inside the bash script itself (`openssl rand`). There is no Terraform-level password to inject.

Lessons 10+ use Secrets Manager, where the secret ARN is passed via `templatefile()`.

### Why Clone from GitHub Instead of Bundling App Code?

The `single-instance.sh` script clones from `github.com/md-sarowar-alam/terraform-iac-foundations-to-3tier.git`. Alternatives:

| Approach | Pros | Cons |
|---|---|---|
| Clone from GitHub (this lesson) | Script stays small, always gets latest | Requires internet access, depends on GitHub |
| Bundle in user_data via templatefile | Self-contained | Base64-encoded, 16 KB limit |
| S3 bucket pre-signed URL | No internet dependency | Extra S3 setup |
| Custom AMI (Packer) | Fastest boot | Build pipeline required |

For a learning environment, GitHub cloning is simplest. For production, a custom AMI built with Packer (or a container) is standard.

---

## 12. Common Errors and Fixes

### `Error: InvalidKeyPair.NotFound`

```
Error: InvalidKeyPair.NotFound: The key pair 'sarowar-ostad-mumbai' does not exist
```

**Cause:** The key pair name in `key_name` variable does not match what is in `ap-south-1`.

**Fix:**
```bash
# List existing key pairs
aws ec2 describe-key-pairs --region ap-south-1 --query "KeyPairs[].KeyName" --output text

# Update terraform.tfvars with the correct name
key_name = "your-actual-key-pair-name"
```

### `Error: UnauthorizedOperation` on RunInstances

```
Error: UnauthorizedOperation: You are not authorized to perform this operation
```

**Cause:** IAM user lacks `ec2:RunInstances` permission, or there is a Service Control Policy blocking EC2 launch.

**Fix:** Add the EC2 permissions listed in Section 5, or assume a role with sufficient permissions.

### Apply Completes but Health Check Fails After 5 Minutes

```bash
curl: (7) Failed to connect to 13.x.x.x port 80: Connection refused
```

**Cause 1:** `user_data` script still running (early call).
**Cause 2:** `user_data` script failed partway through.

**Diagnose:**
```bash
ssh -i sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
sudo tail -100 /var/log/user-data.log
```

Look for error lines. Common failure points:
- `git clone` fails - GitHub temporarily unreachable, or rate limited
- `npm ci` fails - npm registry unreachable, or package-lock.json mismatch
- PostgreSQL `createuser` fails - ran script twice (user already exists)

**Fix:** If script failed, re-create the instance:
```bash
terraform apply -replace="module.single_instance.aws_instance.this"
```

### SSH: `Permission denied (publickey)`

```
ubuntu@13.x.x.x: Permission denied (publickey).
```

**Cause 1:** Wrong `.pem` file - you have multiple key pairs.
**Cause 2:** Wrong username - EC2 instances have fixed usernames based on the AMI.

Ubuntu 22.04 AMI default user: `ubuntu` (not `ec2-user`, not `admin`, not `root`).

```bash
# Correct SSH command format (matches outputs.tf):
ssh -i sarowar-ostad-mumbai.pem ubuntu@<public_ip>
```

**Cause 3:** `.pem` file permissions too open.
```bash
chmod 400 sarowar-ostad-mumbai.pem
```

### SSH Timeout (Connection Refused/Timeout)

**Cause:** Your current IP does not match `allowed_ssh_cidr`.

**Fix:** Update the CIDR and re-apply:
```bash
MY_IP=$(curl -s ifconfig.me)
# Edit terraform.tfvars: allowed_ssh_cidr = "$MY_IP/32"
terraform apply   # security group update only, ~5 seconds
```

### `tolist(data.aws_subnets.default.ids)[0]` - Index Out of Bounds

```
Error: Invalid index - The given key does not identify an element in this collection value
```

**Cause:** The default VPC has no subnets (someone deleted them).

**Fix:**
```bash
# Check default VPC subnets
aws ec2 describe-subnets \
  --filters "Name=defaultForAz,Values=true" \
  --region ap-south-1 \
  --query "Subnets[].SubnetId" \
  --output text
```

If empty, recreate default subnets:
```bash
aws ec2 create-default-subnet --availability-zone ap-south-1a --region ap-south-1
```

### `Error: InvalidAMIID.NotFound` or Wrong AMI

**Cause:** The AMI data source returned an unexpected result (region mismatch, filter too broad).

**Fix:** Verify what the data source resolved to:
```bash
terraform apply -refresh-only
terraform output   # not applicable here, but check plan output data source resolution
```

Or check directly:
```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --region ap-south-1 \
  --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}" \
  --output table
```

---

## 13. What Comes Next

This lesson creates the simplest possible working application. Every subsequent lesson improves one aspect of this architecture:

| Lesson | Improvement to Lesson 06 |
|---|---|
| **07 - RDS Database** | Move PostgreSQL off EC2 onto managed RDS in the custom VPC |
| **08 - 3-Tier Basic** | Split into separate EC2 instances per tier, use custom VPC |
| **09 - 3-Tier Production** | Add ALB, move backend to private subnet, HTTPS via ACM |
| **10 - Security Best Practices** | Secrets Manager for DB password, IAM roles, encrypted comms |
| **11 - User Data Automation** | Advanced cloud-init patterns, SSM Parameter Store |
| **12 - Bastion Host** | Replace public SSH with bastion jump box in custom VPC |
| **13 - Complete Production** | Assemble all lessons: custom VPC + RDS + ALB + Bastion + Secrets |

The `modules/ec2` module introduced here is designed to be reused in all those lessons. It is intentionally generic - the `role`, `iam_instance_profile`, and `user_data` variables allow it to serve as frontend, backend, or bastion without modification.

---

## Dependency Map

```
terraform.tfvars (allowed_ssh_cidr required)
      |
      v
Root variables.tf
      |
      +-> data "aws_vpc" "default"          (read default VPC id)
      |         |
      +-> data "aws_subnets" "default"      (filter by vpc_id)
      |         |
      |    tolist(...ids)[0] --> subnet_id
      |
      +-> resource "aws_security_group" "single_instance"
      |         vpc_id = data.aws_vpc.default.id
      |         ingress 22 <- var.allowed_ssh_cidr
      |         ingress 80 <- 0.0.0.0/0
      |         ingress 443 <- 0.0.0.0/0
      |
      +-> module "single_instance" {source = "./modules/ec2"}
                |  subnet_id          = first default subnet
                |  security_group_ids = [aws_security_group.single_instance.id]
                |  user_data          = file("scripts/single-instance.sh")
                |  root_volume_size   = 30
                |
                v
        modules/ec2/main.tf
                |
                +-> data "aws_ami" "ubuntu"        (Canonical latest 22.04)
                +-> resource "aws_instance" "this"
                          ami            = data.aws_ami.ubuntu.id
                          root_volume:   gp3, 30 GB, encrypted
                          lifecycle:     create_before_destroy
                          user_data:  --->  scripts/single-instance.sh
                                               |
                                               +-- apt-get: postgresql-14
                                               +-- apt-get: nodejs 18, pm2
                                               +-- git clone: github.com/...
                                               +-- npm ci, npm run build
                                               +-- psql migrations
                                               +-- pm2 start
                                               +-- nginx config + restart
      |
      v
Root outputs.tf
  instance_id, public_ip, app_url, health_check_url, ssh_command, check_logs
```

New patterns from this lesson carried forward to all subsequent lessons:
1. **`file()`** - externalizing large user_data scripts
2. **`data "aws_vpc"` / `data "aws_subnets"`** - reading existing infrastructure
3. **EC2 module** (`modules/ec2/`) - reused unchanged in lessons 08, 09, 12, 13
4. **`lifecycle { create_before_destroy }`** - safe instance replacement
5. **`data "aws_ami"`** - dynamic AMI resolution (never hardcode AMI IDs)

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
