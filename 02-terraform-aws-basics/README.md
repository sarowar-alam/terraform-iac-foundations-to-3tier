# 02 — Terraform AWS Basics

> **Course Position:** Lesson 02 of 13 — Module 8, Section 2: EC2, Security Groups, and User Data
> **Objective:** Deploy a live web server on EC2 that is publicly reachable over HTTP and SSH-accessible from your machine — entirely through Terraform.

This lesson introduces four concepts that appear in every real-world Terraform codebase: `locals`, `default_tags`, security groups, and `user_data`. By the end, you will have a running Nginx web server that serves a custom HTML page, deployed and verifiable without touching the AWS Console.

**Prerequisites:** Complete Lesson 01 first. The core workflow (`init` → `plan` → `apply` → `destroy`) is not re-explained here.

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

This lesson provisions an **Ubuntu 22.04 EC2 instance** with a **security group** and an **automated Nginx installation** using `user_data`. The result is a web server that:

- Serves a custom HTML page on port 80 (publicly accessible)
- Accepts SSH on port 22 from your IP only (not the whole internet)
- Has all three tiers of tagging applied automatically to every resource via `default_tags`
- Uses `locals` to ensure consistent naming across all resources

| New Concept | Where You See It |
|---|---|
| `locals` block | `main.tf` — `name_prefix` and `common_tags` |
| `default_tags` in provider | `main.tf` — provider block |
| Security group with ingress/egress rules | `aws_security_group.web` in `main.tf` |
| Referencing one resource from another | `vpc_security_group_ids = [aws_security_group.web.id]` |
| `data "aws_vpc"` source | `main.tf` — fetches the default VPC |
| Inline `user_data` heredoc script | `aws_instance.web` in `main.tf` |
| Required variable (no default) | `allowed_ssh_cidr` in `variables.tf` |
| Rich outputs (URL, SSH command) | `outputs.tf` — `app_url`, `ssh_command` |

**What this lesson deliberately excludes** (covered in later lessons):

- Custom VPC and subnet (the default VPC is used — introduced in Lesson 05)
- Remote state (local `.tfstate` only — introduced in Lesson 03)
- Modules (monolithic config only — introduced in Lesson 04)
- Application code (Nginx serves a static string, not the BMI app — introduced in Lesson 06)

---

## 2. Technology Stack

### Tools Required on Your Machine

| Tool | Minimum Version | Purpose | Install |
|---|---|---|---|
| Terraform | 1.5.0 | Infrastructure provisioning | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | Credential management + verification | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| curl | any | Get your public IP address | Pre-installed on macOS/Linux; Git Bash on Windows |
| SSH client | any | Connect to the EC2 instance | Pre-installed on macOS/Linux; OpenSSH on Windows 10+ |

### AWS Services Used

| Service | Resource Created | Purpose |
|---|---|---|
| EC2 AMI | `data "aws_ami"` (read-only lookup) | Resolve latest Ubuntu 22.04 LTS AMI ID |
| VPC | `data "aws_vpc"` (read-only lookup) | Resolve the default VPC ID |
| EC2 Security Group | `aws_security_group.web` | Firewall: allow SSH (your IP) + HTTP (all) |
| EC2 Instance | `aws_instance.web` | Ubuntu 22.04, t2.micro, Nginx installed at boot |

### Runtime Software (Installed by `user_data` at Boot)

| Software | Version | How Installed | Purpose |
|---|---|---|---|
| Nginx | latest apt | `apt-get install -y nginx` | Web server serving port 80 |

### Provider Configuration

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

---

## 3. Architecture

### What Gets Created

```
Your Machine (Terraform runs here)
        |
        | AWS API calls (HTTPS)
        v
AWS ap-south-1 (Mumbai) — Default VPC
        |
        +-- aws_security_group.web: bmi-health-tracker-dev-basics-sg
        |       Inbound rules:
        |         Port 22 (TCP) <- YOUR IP/32 only (SSH)
        |         Port 80 (TCP) <- 0.0.0.0/0      (HTTP public)
        |       Outbound rules:
        |         All traffic   -> 0.0.0.0/0
        |
        +-- aws_instance.web: bmi-health-tracker-dev-basics-ec2
                AMI:           Ubuntu 22.04 LTS (dynamically resolved)
                Instance type: t2.micro (1 vCPU, 1 GB RAM)
                Security group: bmi-health-tracker-dev-basics-sg (above)
                Key pair:      sarowar-ostad-mumbai
                user_data:     installs Nginx + writes custom HTML at first boot
                Tags (on this resource):
                  Name        = bmi-health-tracker-dev-basics-ec2
                Tags (from default_tags, on ALL resources automatically):
                  Project     = bmi-health-tracker
                  Environment = dev
                  ManagedBy   = terraform
```

### Network Layout

```
Internet
    |
    | :80 HTTP (all IPs allowed)
    | :22 SSH  (your IP/32 only)
    v
[Default VPC — auto-assigned public subnet]
    |
    +-- EC2: Ubuntu 22.04 + Nginx
             Public IP: (dynamic — shown in terraform output)
             No Elastic IP: IP changes if instance is stopped/started
```

### Traffic Flow After Deployment

```
Browser: http://<public_ip>
    |
    +--> EC2 port 80 --> Nginx --> /var/www/html/index.html
                                   "Hello from Terraform! Instance: <hostname>"

SSH: ssh -i key.pem ubuntu@<public_ip>
    |
    +--> EC2 port 22 --> Linux shell (ubuntu user)
         (only works from YOUR IP — anyone else gets timeout)
```

### Resource Dependency Graph

```
data.aws_ami.ubuntu           (no deps — independent API call)
data.aws_vpc.default          (no deps — independent API call)
      |
      v
aws_security_group.web        depends on: data.aws_vpc.default.id
      |
      v
aws_instance.web              depends on: data.aws_ami.ubuntu.id
                                          aws_security_group.web.id
```

Terraform resolves this graph automatically. It creates the security group before the EC2 instance because the instance references the SG's ID.

---

## 4. Folder Structure and File Reference

```
02-terraform-aws-basics/
|-- main.tf                   Provider + locals + data sources + SG + EC2 resource
|-- variables.tf              6 input variables (1 required, 5 with defaults)
|-- outputs.tf                4 outputs including app_url and ssh_command
|-- terraform.tfvars.example  Template — copy to terraform.tfvars before deploying
|-- README.md                 This file
|
|-- (auto-generated by Terraform — do not commit *.tfstate or .terraform/)
|-- .terraform/               Provider binaries (downloaded by terraform init)
|-- .terraform.lock.hcl       Provider version lock file (DO commit this)
+-- terraform.tfstate         Live state file (never edit or delete before destroy)
```

### File-by-File Explanation

#### `main.tf`

**`locals` block:**
```hcl
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```
`locals` are computed values that can be referenced as `local.name_prefix` throughout the config. They are not variables (cannot be overridden by the caller) and not outputs (not exposed outside the config). Use them to avoid repeating the same expression in multiple places. `name_prefix` produces `bmi-health-tracker-dev` from the default values.

**`default_tags` in the provider:**
```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}
```
Every AWS resource created by this provider automatically receives `Project`, `Environment`, and `ManagedBy` tags — without writing `tags = local.common_tags` in every resource block. This is an AWS provider v4+ feature. Tags set directly on a resource block are merged with `default_tags` (resource-level tags win on conflict).

**`data "aws_vpc" "default"`:**
```hcl
data "aws_vpc" "default" {
  default = true
}
```
Looks up the default VPC that AWS created automatically in `ap-south-1`. Returns its `id`, which is used in the security group's `vpc_id`. This avoids hardcoding a VPC ID. In Lesson 05, this is replaced with a custom VPC module.

**`aws_security_group.web`:**
Three rule types — `ingress` (inbound), `egress` (outbound), note there is no explicit `deny`. AWS security groups are *deny-all by default* for inbound; you only write `allow` rules.

- SSH ingress is restricted to `var.allowed_ssh_cidr` (your IP/32) — not `0.0.0.0/0`, which would expose SSH to the entire internet
- HTTP ingress allows `0.0.0.0/0` so the web server is publicly accessible
- Egress `protocol = "-1"` is AWS syntax for "all protocols" — allows the instance to make outbound calls (apt updates, DNS, etc.)

**`aws_instance.web` — `user_data` heredoc:**
```hcl
user_data = <<-EOF
  #!/bin/bash
  apt-get update -y
  apt-get install -y nginx
  echo "<h1>Hello from Terraform!</h1><p>Instance: $(hostname)</p>" > /var/www/html/index.html
  systemctl enable nginx && systemctl start nginx
EOF
```
`<<-EOF` is a HCL heredoc. The `-` strips leading whitespace (indentation). This bash script runs once at first boot via `cloud-init`. It:
1. Updates the apt package list
2. Installs Nginx
3. Overwrites the default Nginx index page with a custom message (including the hostname from the running bash context — `$(hostname)` is a shell substitution, not a Terraform interpolation)
4. Enables Nginx to start on reboot and starts it immediately

The script takes 1–3 minutes to complete after the instance reaches "running" state.

#### `variables.tf`

| Variable | Default | Required? | Purpose |
|---|---|---|---|
| `aws_region` | `ap-south-1` | No | AWS region |
| `project_name` | `bmi-health-tracker` | No | Resource name prefix |
| `environment` | `dev` | No | Environment tag value |
| `instance_type` | `t2.micro` | No | EC2 instance class |
| `key_name` | `sarowar-ostad-mumbai` | No | SSH key pair name |
| `allowed_ssh_cidr` | *(none)* | **Yes** | Your IP in CIDR format |

`allowed_ssh_cidr` has no default value intentionally. If you run `terraform apply` without this variable set (no `terraform.tfvars`, no `-var` flag), Terraform will **prompt you interactively**:
```
var.allowed_ssh_cidr
  Your IP address in CIDR notation: x.x.x.x/32

  Enter a value:
```
This prevents accidentally leaving SSH unrestricted (`0.0.0.0/0`) by making the engineer explicitly provide their IP every time.

#### `outputs.tf`

| Output | Value | Purpose |
|---|---|---|
| `instance_id` | `aws_instance.web.id` | AWS resource ID for further CLI queries |
| `public_ip` | `aws_instance.web.public_ip` | Raw IP for scripting |
| `app_url` | `"http://${aws_instance.web.public_ip}"` | Click or paste directly in browser |
| `ssh_command` | `"ssh -i sarowar-ostad-mumbai.pem ubuntu@${...}"` | Paste directly in terminal |

The `ssh_command` and `app_url` outputs eliminate the need to manually construct connection strings — a QoL pattern worth reusing in your own configurations.

#### `terraform.tfvars.example`

```hcl
aws_region       = "ap-south-1"
project_name     = "bmi-health-tracker"
environment      = "dev"
instance_type    = "t2.micro"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "YOUR_IP/32"   # run: curl ifconfig.me
```

The only value you must change is `allowed_ssh_cidr`. Replace `YOUR_IP` with the output of `curl ifconfig.me`.

---

## 5. Prerequisites

### 5.1 Terraform and AWS CLI

Follow the installation steps in [Lesson 01, Section 5](../01-terraform-fundamentals/README.md#5-prerequisites). Both must be installed and working before continuing.

Quick verification:
```bash
terraform version   # must be >= 1.5.0
aws sts get-caller-identity   # must return your account ID
```

### 5.2 EC2 Key Pair — Required for SSH

Unlike Lesson 01 (which tagged the key name but never used it), **this lesson actually uses SSH** to connect to the instance. The key pair `sarowar-ostad-mumbai` must exist in `ap-south-1` and the `.pem` file must be on your machine.

Verify the key pair exists:
```bash
aws ec2 describe-key-pairs \
  --key-names sarowar-ostad-mumbai \
  --region ap-south-1
```

If it does not exist, create it:
1. AWS Console → EC2 → Key Pairs → Create key pair
2. Name: `sarowar-ostad-mumbai`, format: `.pem`, click Create
3. The `.pem` file downloads automatically — move it somewhere permanent

Set file permissions (macOS/Linux — SSH refuses keys with open permissions):
```bash
chmod 400 ~/sarowar-ostad-mumbai.pem
```

Windows (PowerShell):
```powershell
icacls "sarowar-ostad-mumbai.pem" /inheritance:r /grant:r "$($env:USERNAME):R"
```

### 5.3 Get Your Public IP Address

```bash
curl ifconfig.me
# Example output: 203.0.113.45
```

You will use this as `allowed_ssh_cidr = "203.0.113.45/32"` in `terraform.tfvars`. The `/32` means exactly that one IP address — no range.

**Important:** If your IP changes after deployment (e.g., your router restarts or you move networks), SSH will stop working because the security group still has your old IP. Fix: update `allowed_ssh_cidr` in `terraform.tfvars` and run `terraform apply` — the security group will be updated in-place without recreating the EC2 instance.

### 5.4 IAM Permissions Required

Your AWS user or role needs these permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeImages",
    "ec2:DescribeVpcs",
    "ec2:CreateSecurityGroup",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:DescribeSecurityGroups",
    "ec2:DeleteSecurityGroup",
    "ec2:RunInstances",
    "ec2:DescribeInstances",
    "ec2:TerminateInstances",
    "ec2:CreateTags"
  ],
  "Resource": "*"
}
```

`AdministratorAccess` or `PowerUserAccess` covers all of the above.

---

## 6. Step-by-Step Deployment

### Step 1: Navigate to This Folder

```bash
cd 02-terraform-aws-basics
```

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — the only line you **must** change:
```hcl
allowed_ssh_cidr = "203.0.113.45/32"   # replace with your IP from: curl ifconfig.me
```

All other values are ready to use as-is.

### Step 3: Initialize

```bash
terraform init
```

Expected output (last line):
```
Terraform has been successfully initialized!
```

### Step 4: Plan

```bash
terraform plan
```

You should see **2 resources to add**: the security group and the EC2 instance. The data sources (AMI, VPC) are read-only and do not appear in the `to add` count.

Expected summary line:
```
Plan: 2 to add, 0 to change, 0 to destroy.
```

Verify the security group rules in the plan — confirm SSH shows your IP, not `0.0.0.0/0`:
```
+ ingress {
    + cidr_blocks = ["203.0.113.45/32"]   <- your IP, correct
    + from_port   = 22
    + to_port     = 22
    ...
  }
```

### Step 5: Apply

```bash
terraform apply
```

Type `yes` when prompted. Creation takes approximately 30–45 seconds.

Expected output after apply:
```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

app_url      = "http://13.x.x.x"
instance_id  = "i-0xxxxxxxxxxxxxxxx"
public_ip    = "13.x.x.x"
ssh_command  = "ssh -i sarowar-ostad-mumbai.pem ubuntu@13.x.x.x"
```

### Step 6: Wait for user_data to Complete

The EC2 instance is in "running" state immediately after Terraform finishes, but the `user_data` script (Nginx installation) runs in the background for 1–3 minutes. The HTTP endpoint will return a connection error until it completes.

To watch progress in real time (after SSH is available — see Step 7):
```bash
# SSH in first, then:
sudo tail -f /var/log/cloud-init-output.log
```

Or simply wait 2 minutes and test for HTTP.

---

## 7. Verifying the Deployment

### Test HTTP (Web Server)

```bash
# Quick test — expect "Hello from Terraform!"
curl http://$(terraform output -raw public_ip)

# Or open the URL from the output in a browser
terraform output app_url
```

Expected response:
```html
<h1>Hello from Terraform!</h1><p>Instance: ip-10-x-x-x</p>
```

If you get `curl: (7) Failed to connect` — the user_data script is still running. Wait 60 seconds and retry.

### Connect via SSH

```bash
# Use the ready-made command from outputs
eval $(terraform output -raw ssh_command | sed 's/^//')

# Or manually:
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
```

Confirming you are on the right instance:
```bash
# On the EC2 instance
hostname
cat /var/www/html/index.html
sudo systemctl status nginx
sudo cat /var/log/cloud-init-output.log | tail -20
```

### Verify Tags are Applied to Both Resources

```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Project:Tags[?Key=='Project']|[0].Value}" \
  --output table
```

Check the security group tags too:
```bash
aws ec2 describe-security-groups \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" \
  --query "SecurityGroups[].{Name:GroupName,Project:Tags[?Key=='Project']|[0].Value,Env:Tags[?Key=='Environment']|[0].Value}" \
  --output table
```

Both resources should show `Project = bmi-health-tracker` and `Environment = dev` from `default_tags`.

### Verify via AWS Console

1. Open https://console.aws.amazon.com/ec2 → ap-south-1
2. **Instances** — find `bmi-health-tracker-dev-basics-ec2`, state: Running
3. Click the instance → **Tags** tab — confirm `Project`, `Environment`, `ManagedBy` tags
4. **Security Groups** — find `bmi-health-tracker-dev-basics-sg`
5. Click it → **Inbound rules** tab — confirm port 22 shows your IP CIDR, port 80 shows `0.0.0.0/0`

---

## 8. Understanding the Code

### Why `locals` Instead of Variables?

`locals` are for values **computed from other values** within the same configuration that you want to reuse without repeating the expression. Key differences:

| | `variable` | `local` |
|---|---|---|
| Can be overridden by caller | Yes (tfvars, -var, env var) | No |
| Supports expressions | No (only type/default) | Yes (any HCL expression) |
| Use case | External inputs | Internal derived values |

`name_prefix = "${var.project_name}-${var.environment}"` is a derived value — it is always the combination of two variables. Making it a `local` means you update it in one place if the pattern changes.

### How `default_tags` Works

`default_tags` is a feature of the AWS Terraform provider (v3.38.0+). Tags in this block are automatically merged into every `tags` attribute of every resource the provider manages.

```hcl
provider "aws" {
  default_tags {
    tags = {
      Project     = "bmi-health-tracker"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

resource "aws_instance" "web" {
  tags = {
    Name = "my-instance"   # only Name is set here
  }
  # AWS Console will show: Name, Project, Environment, ManagedBy
}
```

**Merge behaviour:** If a resource sets the same tag key as `default_tags`, the resource-level value wins. For example, if the EC2 instance sets `Environment = "prod"` but `default_tags` has `Environment = "dev"`, the instance gets `Environment = "prod"`.

`terraform plan` shows `default_tags` contributions in the output under `tags_all` (distinct from the per-resource `tags` attribute).

### Why `data "aws_vpc" "default"`?

Rather than hardcoding a VPC ID in the security group:
```hcl
vpc_id = "vpc-0abc123"   # BAD: hardcoded, breaks in any other AWS account
```

The data source looks it up dynamically:
```hcl
data "aws_vpc" "default" { default = true }
...
vpc_id = data.aws_vpc.default.id   # GOOD: works in any account/region
```

Every AWS account/region has a default VPC created automatically. `default = true` filters to exactly that VPC. In Lesson 05, this is replaced with a custom VPC so the default VPC is no longer needed.

### Security Group Rules — Inbound vs Outbound

```
Security Group Evaluation:
  Inbound traffic:  AWS checks ALL ingress rules — if any match, traffic is allowed
  Outbound traffic: AWS checks ALL egress rules — if any match, traffic is allowed
  Default:          DENY ALL (implicit — no deny rule needed)
  Statefulness:     If inbound SSH is allowed, the response packets are automatically
                    allowed back out — you never need to write an egress rule for replies
```

The egress rule `protocol = "-1"` with `cidr_blocks = ["0.0.0.0/0"]` allows all outbound — necessary for `apt-get` and other outbound calls from the instance.

### `user_data` Execution

```
EC2 instance launch
     |
     v
cloud-init runs (Amazon's boot automation system)
     |
     v
Executes /var/lib/cloud/instance/scripts/part-001 (your user_data script)
     |  (runs as root, in the background, ~1-3 minutes)
     v
Log: /var/log/cloud-init-output.log
     |
     +-- apt-get update
     +-- apt-get install nginx
     +-- echo ... > /var/www/html/index.html
     +-- systemctl enable nginx
     +-- systemctl start nginx
```

**Important behaviours:**
- Runs exactly **once** at first launch (not on restart)
- Runs as `root` — no `sudo` needed inside the script
- If the script fails, the instance still reaches "running" state — there is no automatic rollback
- To re-run user_data, you must destroy and recreate the instance (or use `user_data_replace_on_change = true`)
- Logs are at `/var/log/cloud-init-output.log` — always check this first when the app is not responding

### The `$(hostname)` Inside `user_data`

```hcl
user_data = <<-EOF
  echo "<h1>Hello from Terraform!</h1><p>Instance: $(hostname)</p>" > /var/www/html/index.html
EOF
```

`$(hostname)` is a **bash command substitution**, not a Terraform interpolation. At the time Terraform reads this heredoc, `$(hostname)` is treated as a plain string — Terraform does not evaluate it. When the bash script runs on the EC2 instance, bash evaluates `$(hostname)` and substitutes the instance's hostname (e.g., `ip-10-0-1-50`).

This is different from `${var.project_name}`, which Terraform evaluates at plan time before the script even reaches the instance.

---

## 9. Making Changes Safely

### Update Your SSH IP (After Network Change)

If your public IP changed, SSH will time out. Fix:

```bash
# Get your new IP
curl ifconfig.me

# Update terraform.tfvars
allowed_ssh_cidr = "NEW_IP/32"

# Apply — security group rule is updated in-place (no EC2 recreation)
terraform plan    # expect: ~ aws_security_group.web (ingress rule change only)
terraform apply
```

### Change the Environment Tag

```bash
# In terraform.tfvars:
environment = "staging"

terraform plan
```

This changes:
- `local.name_prefix` → `bmi-health-tracker-staging`
- The `Environment` tag on all resources (via `default_tags`)
- The `Name` tag on the EC2 and SG (via `local.name_prefix`)

Renaming the security group **forces replacement** (AWS requires a new SG to have a new name). Since the EC2 references the SG, **both resources are replaced**. The plan will show `-/+` for both. This is expected when changing resource names.

### Change Instance Type

```bash
# In terraform.tfvars:
instance_type = "t3.micro"

terraform plan    # shows: -/+ aws_instance.web (forces replacement)
terraform apply
```

Changing `instance_type` forces EC2 replacement. You get a new instance ID and a new public IP. Update your SSH config accordingly after apply.

### Add a Port to the Security Group

Edit `main.tf` — add a new `ingress` block inside `aws_security_group.web`:
```hcl
ingress {
  description = "HTTPS"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

Then:
```bash
terraform plan    # shows: ~ aws_security_group.web (in-place rule addition)
terraform apply
```

Security group rule additions are **in-place** — no EC2 recreation.

### Modify the Web Page Content

Edit the `echo` line inside `user_data` in `main.tf`:
```hcl
echo "<h1>Updated Page</h1>" > /var/www/html/index.html
```

```bash
terraform plan    # shows: ~ aws_instance.web (user_data change)
```

By default, changing `user_data` does **not** recreate the instance — Terraform records the change in state but user_data only runs at first launch. The live instance still serves the old page.

To force the new script to run, add this lifecycle block to `aws_instance.web`:
```hcl
lifecycle {
  replace_on_changes = [user_data]
}
```

This will cause `terraform apply` to destroy and recreate the instance, running the new `user_data` script.

---

## 10. Cleanup

```bash
terraform destroy
```

Terraform destroys resources in reverse dependency order:
1. `aws_instance.web` (destroyed first — depends on the SG)
2. `aws_security_group.web` (destroyed after — the EC2 must be gone before the SG can be deleted)

Expected output:
```
Plan: 0 to add, 0 to change, 2 to destroy.
...
Destroy complete! Resources: 2 destroyed.
```

After destroy, verify no resources remain:
```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected: empty

aws ec2 describe-security-groups \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" \
  --query "SecurityGroups[].GroupName" \
  --output text
# Expected: empty (or only default SG which Terraform does not manage)
```

---

## 11. Key Concepts and Design Decisions

### Why Restrict SSH to `/32` Instead of `/0`?

`0.0.0.0/0` on port 22 exposes SSH to every IP on the internet. Automated bots continuously scan public IPs for open port 22 and attempt brute-force logins. While Ubuntu's default ssh config blocks password auth (key-only), this is still a security risk. Restricting to `/32` (a single IP) means only your machine can even attempt a connection.

### Why No Elastic IP?

An Elastic IP (EIP) gives the instance a fixed public IP that survives stop/start cycles. This lesson intentionally omits it to demonstrate a common gotcha: **the public IP changes if you stop and start the instance** (not restart — `reboot` keeps the IP). For a learning exercise, this is acceptable. Production deployments use EIPs or put an ALB in front (which has a fixed DNS name).

### `default_tags` vs Per-Resource `tags`

Setting `tags = local.common_tags` in every resource is error-prone — developers forget it, copy/paste errors introduce inconsistencies, and auditing becomes difficult. `default_tags` solves this by making three tags unconditional. The pattern from this lesson is used in every remaining lesson and in all production modules.

### Why the Default VPC?

Custom VPC configuration (subnets, route tables, NAT gateways) is a significant topic taught in Lesson 05. Using `data "aws_vpc" "default"` here keeps the focus on the new concepts (locals, default_tags, security groups, user_data) without introducing networking complexity. Every AWS account has a default VPC, making this configuration portable across accounts.

### Security Group as a Separate Resource vs Inline Rules

Terraform supports two ways to define security group rules:
1. **Separate `aws_security_group_rule` resources** — more flexible, allows rules to be added/removed independently
2. **Inline `ingress`/`egress` blocks** (used here) — simpler, entire SG is managed as one unit

This lesson uses inline blocks because they are easier to read and sufficient for a standalone configuration. Separate resources are used in the shared modules (Lessons 05+) where modules need to add rules to existing SGs.

---

## 12. Common Errors and Fixes

### `Error: missing required argument "allowed_ssh_cidr"`

```
Error: No value for required variable

  on variables.tf line 24, in variable "allowed_ssh_cidr":
  24: variable "allowed_ssh_cidr" {
```

**Cause:** `terraform.tfvars` does not exist or `allowed_ssh_cidr` is not set in it.

**Fix:**
```bash
cp terraform.tfvars.example terraform.tfvars
# Then edit: allowed_ssh_cidr = "YOUR_REAL_IP/32"
```

### `Error: InvalidParameterValue: invalid CIDR`

```
Error: creating EC2 Security Group Rule: InvalidParameterValue: Invalid CIDR
```

**Cause:** `allowed_ssh_cidr` is missing the `/32` suffix.

**Fix:** Change `203.0.113.45` to `203.0.113.45/32` in `terraform.tfvars`.

### SSH: `Connection timed out`

**Cause A:** Your IP has changed since deployment.
```bash
curl ifconfig.me
# If this is different from what is in terraform.tfvars, update it and re-apply
```

**Cause B:** `user_data` is still running — wait 2 minutes.

**Cause C:** You are using the wrong `.pem` file path.
```bash
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@<ip>   # explicit path
```

**Cause D:** Wrong username. Ubuntu 22.04 on EC2 uses `ubuntu`, not `ec2-user`, `admin`, or `root`.

### SSH: `WARNING: UNPROTECTED PRIVATE KEY FILE!`

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
WARNING: UNPROTECTED PRIVATE KEY FILE!
Permissions 0644 for 'sarowar-ostad-mumbai.pem' are too open.
```

**Fix:**
```bash
chmod 400 ~/sarowar-ostad-mumbai.pem
```

### HTTP: No Response for 2+ Minutes After Apply

**Cause:** `user_data` took longer than expected, or the script failed.

**Fix:** SSH into the instance and check the cloud-init log:
```bash
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
sudo cat /var/log/cloud-init-output.log | tail -30
sudo systemctl status nginx
```

If Nginx is not running:
```bash
sudo systemctl start nginx
sudo systemctl status nginx
```

### `Error: DependencyViolation` on Destroy

```
Error: DependencyViolation: resource sg-xxx has a dependent object
```

**Cause:** The security group still has a network interface (the EC2 instance) attached to it. This can happen if a previous destroy partially failed.

**Fix:** Destroy the EC2 instance first, then the SG:
```bash
terraform destroy -target=aws_instance.web
terraform destroy
```

---

## 13. What Comes Next

| Lesson | Builds on This Lesson |
|---|---|
| **03 — State Management** | Move `terraform.tfstate` to S3 → enables team collaboration and drift protection |
| **04 — Modules** | Refactor the EC2 + SG pattern into a reusable module |
| **05 — Networking VPC** | Replace `data "aws_vpc" "default"` with a custom VPC (6 subnets, NAT GW) |
| **06 — EC2 Deployment** | Replace the Nginx demo `user_data` with the full BMI app stack (PostgreSQL + Node.js + React) |
| **11 — User Data Automation** | Replace inline heredoc with `templatefile()` for dynamic variable injection into boot scripts |

---

## Dependency Map

```
terraform.tfvars
      |
      v
variables.tf  <--------------------- main.tf reads var.*
                                           |
                              +------------+------------+
                              |                         |
                    data.aws_ami.ubuntu        data.aws_vpc.default
                              |                         |
                              |               aws_security_group.web
                              |                  (vpc_id from data.aws_vpc)
                              |                         |
                              +-------> aws_instance.web
                                    (ami from data.aws_ami)
                                    (sg from aws_security_group.web.id)
                                          |
                                          v
                                     outputs.tf  <-- instance.id, .public_ip
```

Two new dependency types appear in this lesson compared to Lesson 01:
1. **Resource-to-data-source:** `aws_security_group.web` depends on `data.aws_vpc.default.id`
2. **Resource-to-resource:** `aws_instance.web` depends on `aws_security_group.web.id`

Terraform resolves these automatically by reading the dependency graph at plan time.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
