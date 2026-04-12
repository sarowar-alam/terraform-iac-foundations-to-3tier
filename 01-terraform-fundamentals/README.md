# 01 — Terraform Fundamentals

> **Course Position:** Lesson 01 of 13 — Module 8, Section 1: Introduction to Infrastructure as Code
> **Objective:** Build and destroy your first AWS EC2 instance entirely through code, mastering the core Terraform workflow.

This lesson contains no modules, no scripts, and no remote state. Every concept introduced here — provider configuration, data sources, resources, variables, outputs, and state — underpins every lesson that follows. Take the time to understand each file before moving on.

---

## Table of Contents

1. [What This Lesson Does](#1-what-this-lesson-does)
2. [Technology Stack](#2-technology-stack)
3. [Architecture](#3-architecture)
4. [Folder Structure and File Reference](#4-folder-structure-and-file-reference)
5. [Prerequisites](#5-prerequisites)
6. [Step-by-Step Deployment](#6-step-by-step-deployment)
7. [Verifying and Exploring the Deployment](#7-verifying-and-exploring-the-deployment)
8. [Understanding the Code](#8-understanding-the-code)
9. [Making Changes Safely](#9-making-changes-safely)
10. [Cleanup](#10-cleanup)
11. [Key Concepts and Design Decisions](#11-key-concepts-and-design-decisions)
12. [Common Errors and Fixes](#12-common-errors-and-fixes)
13. [What Comes Next](#13-what-comes-next)

---

## 1. What This Lesson Does

This lesson provisions a **single Ubuntu 22.04 EC2 instance** in AWS `ap-south-1` using Terraform. It intentionally covers only the minimum required to introduce:

| Concept | Where You See It |
|---|---|
| Terraform workflow | `init` → `plan` → `apply` → `destroy` |
| Provider configuration | `terraform {}` block + `provider "aws"` in `main.tf` |
| Dynamic AMI lookup | `data "aws_ami"` block in `main.tf` |
| Resource creation | `aws_instance.web` in `main.tf` |
| Input variables | `variables.tf` + `terraform.tfvars` |
| Output values | `outputs.tf` |
| Local state file | `terraform.tfstate` (auto-generated after apply) |
| Version pinning | `required_version` and `required_providers` |

**What this lesson deliberately excludes** (covered in later lessons):

- Security groups (the EC2 has no open ports — it is not reachable without one)
- Key pair association (a key_name is tagged on the instance but SSH requires a SG rule for port 22)
- Remote state (local `.tfstate` file only)
- Modules, scripts, or multi-tier architecture

---

## 2. Technology Stack

### Tools Required on Your Machine

| Tool | Minimum Version | Purpose | Install |
|---|---|---|---|
| Terraform | 1.5.0 | Infrastructure provisioning | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | Credential management + AWS verification | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| A text editor | any | Editing `.tf` and `.tfvars` files | VS Code recommended |

### AWS Services Touched by This Lesson

| Service | What Terraform Does |
|---|---|
| EC2 | Creates one `t2.micro` instance (Ubuntu 22.04 LTS) |
| EC2 AMI (data source) | Queries AWS for the latest Ubuntu 22.04 AMI ID — read-only, nothing created |
| IAM (implicit) | Your AWS credentials authorize the EC2 CreateInstance API call |

### AWS Provider

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

`~> 5.0` means: use any version `>= 5.0.0` and `< 6.0.0`. This pins the major version to avoid breaking changes while allowing patch/minor upgrades.

---

## 3. Architecture

### What Gets Created

```
Your Machine (Terraform runs here)
        |
        | AWS API calls (HTTPS)
        v
AWS ap-south-1 (Mumbai)
        |
        +-- EC2 Instance: bmi-health-tracker-first-instance
                AMI:           Ubuntu 22.04 LTS (dynamically fetched)
                Instance Type: t2.micro (1 vCPU, 1 GB RAM)
                Subnet:        Default VPC, default subnet
                Storage:       8 GB gp2 (default root volume)
                Networking:    No security group attached (no open ports)
                Tags:
                  Name        = bmi-health-tracker-first-instance
                  Environment = learning
                  ManagedBy   = terraform
```

### What Does NOT Get Created

- No security group → the instance cannot accept inbound connections (port 22 is closed)
- No Elastic IP → the instance gets a temporary public IP that changes on stop/start
- No persistent storage beyond the default root volume
- This is intentional — the focus is on Terraform mechanics, not application architecture

### Data Flow

```
terraform apply
     |
     +-- Calls EC2 DescribeImages API --> Finds latest Ubuntu 22.04 AMI id  (data source)
     +-- Calls EC2 RunInstances API   --> Creates the EC2 instance           (resource)
     +-- Writes terraform.tfstate     --> Records what was created           (local file)
     +-- Prints outputs               --> instance_id, public_ip, public_dns, ami_used
```

---

## 4. Folder Structure and File Reference

```
01-terraform-fundamentals/
|-- main.tf                   The core configuration file
|-- variables.tf              Input variable declarations
|-- outputs.tf                Output value declarations
|-- terraform.tfvars.example  Template — copy to terraform.tfvars before deploying
|-- README.md                 This file
|
|-- (auto-generated by Terraform — do not commit)
|-- .terraform/               Provider binaries (downloaded by terraform init)
|-- .terraform.lock.hcl       Provider version lock file (DO commit this)
+-- terraform.tfstate         Live state — records what AWS resources Terraform owns
```

### File-by-File Explanation

#### `main.tf`

The single source of truth for what infrastructure to create.

- **`terraform {}` block** — Sets the Terraform version constraint and declares the AWS provider dependency.
- **`provider "aws"` block** — Configures the AWS provider with the target region. Uses `var.aws_region` so the region can be changed without editing the provider block.
- **`data "aws_ami" "ubuntu"` block** — A *read-only* lookup against the AWS EC2 API. Finds the most recent Ubuntu 22.04 LTS AMI published by Canonical (owner ID `099720109477`). The two `filter` blocks narrow the result to: the exact naming pattern and HVM virtualization type. This guarantees you always get a current, unambiguous AMI without hardcoding a region-specific AMI ID.
- **`resource "aws_instance" "web"` block** — Creates one EC2 instance. References `data.aws_ami.ubuntu.id` so the AMI is always current.

#### `variables.tf`

Declares what inputs the configuration accepts. Each variable has a `description`, `type`, and `default`. Because defaults are provided, this lesson can run with `terraform apply` without a `.tfvars` file — but using one is good practice.

| Variable | Default | Purpose |
|---|---|---|
| `aws_region` | `ap-south-1` | AWS region to deploy into |
| `instance_type` | `t2.micro` | EC2 instance class |
| `key_name` | `sarowar-ostad-mumbai` | Key pair name for the instance tag |
| `project_name` | `bmi-health-tracker` | Prefix applied to the instance Name tag |

#### `outputs.tf`

Declares values to display after `terraform apply` completes and to expose to other Terraform configurations. Four outputs are defined:

| Output | Source | What It Shows |
|---|---|---|
| `instance_id` | `aws_instance.web.id` | The AWS resource ID (e.g., `i-0abc123def`) |
| `public_ip` | `aws_instance.web.public_ip` | The temporary public IP address |
| `public_dns` | `aws_instance.web.public_dns` | The amazonaws.com DNS name |
| `ami_used` | `data.aws_ami.ubuntu.id` | Which AMI was dynamically selected |

#### `terraform.tfvars.example`

A safe-to-commit template. Copy it to `terraform.tfvars` and edit it. The `.gitignore` in the repo root blocks `*.tfvars` (in case you add secrets later) but allows `*.tfvars.example`.

---

## 5. Prerequisites

### 5.1 Install Terraform

```bash
# macOS (Homebrew)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Ubuntu/Debian
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Windows
winget install Hashicorp.Terraform
# or download from: https://developer.hashicorp.com/terraform/install

# Verify
terraform version
# Must show: Terraform v1.5.0 or higher
```

### 5.2 Install and Configure AWS CLI

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Windows
winget install Amazon.AWSCLI

# Verify
aws --version
# Must show: aws-cli/2.x.x
```

Configure credentials:
```bash
aws configure
# AWS Access Key ID:     <paste your access key>
# AWS Secret Access Key: <paste your secret key>
# Default region name:   ap-south-1
# Default output format: json
```

Credentials are stored in `~/.aws/credentials`. Never put AWS keys in `.tf` files.

### 5.3 Verify Your AWS Identity

```bash
aws sts get-caller-identity
```

Expected output (your account ID and user ARN):
```json
{
    "UserId": "AIDA...",
    "Account": "388779989543",
    "Arn": "arn:aws:iam::388779989543:user/your-username"
}
```

If this command fails, your credentials are not configured correctly. Stop and fix this before proceeding.

### 5.4 IAM Permissions Required

Your AWS user or role needs the following IAM permissions to run this lesson:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeImages",
    "ec2:RunInstances",
    "ec2:DescribeInstances",
    "ec2:TerminateInstances",
    "ec2:CreateTags"
  ],
  "Resource": "*"
}
```

If your account has `AdministratorAccess` or `PowerUserAccess`, this is already covered.

### 5.5 EC2 Key Pair (for Reference Only)

This lesson tags `key_name = "sarowar-ostad-mumbai"` on the instance but **does not use it for SSH** (there is no security group allowing port 22). The key pair must exist in `ap-south-1` for the tags to be valid.

To verify:
```bash
aws ec2 describe-key-pairs \
  --key-names sarowar-ostad-mumbai \
  --region ap-south-1
```

If it does not exist, either create it in the AWS Console (EC2 → Key Pairs → Create) or change `key_name` in `terraform.tfvars` to an existing key pair name, or remove the `key_name` line from `main.tf` (it is optional).

---

## 6. Step-by-Step Deployment

### Step 1: Navigate to This Folder

```bash
cd 01-terraform-fundamentals
```

All Terraform commands must be run from inside this folder. Terraform reads `.tf` files in the current working directory only.

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

The defaults work as-is for this course. You can open `terraform.tfvars` and confirm the values:

```hcl
aws_region    = "ap-south-1"
instance_type = "t2.micro"
key_name      = "sarowar-ostad-mumbai"
project_name  = "bmi-health-tracker"
```

### Step 3: Initialize

```bash
terraform init
```

What happens:
- Terraform reads `required_providers` in `main.tf`
- Downloads the AWS provider plugin from the Terraform Registry (~50 MB) into `.terraform/`
- Creates `.terraform.lock.hcl` which pins the exact provider version used

Expected output (last 3 lines):
```
Terraform has been successfully initialized!
You may now begin working with Terraform. The primary command is:  terraform plan
```

If you see `Error: Failed to install provider` — check your internet connection or proxy settings.

### Step 4: Plan

```bash
terraform plan
```

Terraform computes what changes need to be made to reach the desired state described in your `.tf` files. Since there is no existing state, everything will be marked for creation.

Read the plan output carefully. You will see:

```
Terraform will perform the following actions:

  # aws_instance.web will be created
  + resource "aws_instance" "web" {
      + ami                          = "ami-0xxxxxxxxxxxxxxxx"  (resolved from data source)
      + instance_type                = "t2.micro"
      + tags                         = {
          + "Environment" = "learning"
          + "ManagedBy"   = "terraform"
          + "Name"        = "bmi-health-tracker-first-instance"
        }
      ...
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

**Legend:**
- `+` (green) — resource will be **created**
- `-` (red) — resource will be **destroyed**
- `~` (yellow/amber) — resource will be **modified in-place**
- `-/+` — resource will be **destroyed and recreated**

A plan that shows `0 to change, 0 to destroy` on first apply confirms you are starting from a clean state.

### Step 5: Apply

```bash
terraform apply
```

Terraform re-displays the plan and asks for confirmation:
```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

Type `yes` and press Enter. (`no` or any other value cancels.)

To skip the prompt (for scripts or CI/CD pipelines — not recommended for learning):
```bash
terraform apply -auto-approve
```

After ~30 seconds, you will see:
```
aws_instance.web: Creation complete after 30s [id=i-0xxxxxxxxxxxxxxxx]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

ami_used    = "ami-0xxxxxxxxxxxxxxxx"
instance_id = "i-0xxxxxxxxxxxxxxxx"
public_dns  = "ec2-xx-xx-xx-xx.ap-south-1.compute.amazonaws.com"
public_ip   = "xx.xx.xx.xx"
```

### Step 6: View Outputs

```bash
# Show all outputs
terraform output

# Show a single output value (no quotes, suitable for scripting)
terraform output -raw public_ip
```

---

## 7. Verifying and Exploring the Deployment

### Verify in the AWS Console

1. Open https://console.aws.amazon.com/ec2
2. Select region **ap-south-1** (Mumbai) — top-right dropdown
3. Go to **Instances** — find `bmi-health-tracker-first-instance`
4. Confirm state: **Running**
5. Check the **Tags** tab — you should see `ManagedBy = terraform`

### Verify with AWS CLI

```bash
# List running instances managed by Terraform in ap-south-1
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,IP:PublicIpAddress,State:State.Name}" \
  --output table
```

### Explore the State File

```bash
# List all resources Terraform is tracking
terraform state list
# Output: aws_instance.web

# Show full details of the EC2 resource in state
terraform state show aws_instance.web

# View the raw state file (JSON — informational, do not edit)
cat terraform.tfstate
```

The state file is the source of truth for what Terraform believes exists in AWS. It contains the EC2 instance ID, IP addresses, AMI ID, all attributes, and metadata. Terraform uses it to compute diffs on the next `terraform plan`.

### Inspect the Lock File

```bash
cat .terraform.lock.hcl
```

This file records the exact version of the AWS provider installed. Commit this file — it ensures every team member and CI pipeline uses the same provider version.

---

## 8. Understanding the Code

### Why `data "aws_ami"` Instead of a Hardcoded AMI ID?

AMI IDs are **region-specific and change over time**. The AMI for Ubuntu 22.04 in `ap-south-1` today is different from last month and from the same OS in `us-east-1`. Hardcoding an AMI ID causes two problems:

1. The AMI may be deprecated or deregistered — causing `terraform apply` to fail with "InvalidAMIID.NotFound"
2. The configuration breaks silently if someone changes the region

The `data "aws_ami"` source solves this:
```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical's official AWS account ID — never changes

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

- `most_recent = true` — if multiple AMIs match, pick the latest
- `owners = ["099720109477"]` — only accept AMIs published by Canonical (prevents picking a malicious third-party AMI with the same name pattern)
- The `name` filter uses a wildcard (`*`) to match all patch versions of Ubuntu 22.04 Jammy
- The `virtualization-type` filter ensures HVM (hardware virtualization) — required for modern instance types

The result is referenced as `data.aws_ami.ubuntu.id` in the resource block.

### How Variable Defaults Work

Variables with defaults don't require a `.tfvars` file. The hierarchy (highest priority wins):

```
1. -var flag on the command line     (highest priority)
2. TF_VAR_* environment variables
3. terraform.tfvars file
4. terraform.tfvars.json file
5. *.auto.tfvars files
6. variable default value            (lowest priority)
```

This lesson uses `terraform.tfvars` file (step 3).

### Resource Naming Convention

```hcl
resource "aws_instance" "web" {
    ^^^^^^^^^^^  ^^^^^^^^^  ^^^
    Type         Name (AWS  Local name (Terraform
    (AWS type,   resource   identifier inside
    predefined)  type)      this config)
```

- The local name `web` is how other blocks reference this resource: `aws_instance.web.public_ip`
- The `Name` tag (`bmi-health-tracker-first-instance`) is what appears in the AWS Console
- These are unrelated — the local name never appears in AWS

### Why No Security Group?

This lesson focuses on Terraform mechanics, not networking. The EC2 instance is created in the **default VPC** with its default security group, which blocks all inbound traffic. You can verify this:

```bash
# SSH will time out — expected behavior for this lesson
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
```

Security groups are added from Lesson 02 onward.

### Local State (No Remote Backend)

This lesson uses a **local state file** (`terraform.tfstate`). The file is created in the same directory as your `.tf` files after `terraform apply` runs.

Consequences:
- If you delete `terraform.tfstate`, Terraform loses track of the EC2 instance and cannot destroy it via `terraform destroy`
- If two people run `terraform apply` simultaneously from different machines, they will create duplicate resources and corrupt each other's state
- This is acceptable for a solo learning exercise — remote state (S3 + DynamoDB locking) is introduced in Lesson 03

**Do not delete `terraform.tfstate` until you have run `terraform destroy`.**

---

## 9. Making Changes Safely

### Change the Instance Type

Edit `terraform.tfvars`:
```hcl
instance_type = "t3.micro"   # was t2.micro
```

Then:
```bash
terraform plan    # must show: ~ aws_instance.web (forces replacement: instance_type)
terraform apply
```

Changing `instance_type` forces EC2 instance **replacement** (destroy old, create new). The plan will show `-/+` (replace). A new instance ID and new IP address will be assigned. This is expected.

### Change the Project Name (Tag Only)

Edit `terraform.tfvars`:
```hcl
project_name = "my-project"
```

Then:
```bash
terraform plan    # must show: ~ aws_instance.web (in-place update: tags only)
terraform apply
```

Changing only tags is an **in-place update** (`~`). The instance is not recreated — only the `Name` tag is updated. Same instance ID, same IP.

### Understand What Forces Replacement

Some attribute changes require destroying and recreating the resource:
- `ami` — changing the OS image
- `instance_type` — changing the hardware class
- `subnet_id` — moving to a different subnet
- `key_name` — changing the SSH key

Others are in-place updates:
- `tags` — metadata only
- `ebs_optimized` — in most cases
- `user_data` — **only** if `user_data_replace_on_change = true` is set

Always read the plan before applying. If a `-/+` replace is unexpected, stop and investigate.

### Always Run Plan Before Apply

```bash
terraform plan -out=tfplan    # save the plan to a file
terraform apply tfplan         # apply exactly that saved plan (no re-computation)
```

Saving the plan to a file guarantees what you reviewed is exactly what gets applied, even if the AWS environment changed between your `plan` and `apply`.

---

## 10. Cleanup

```bash
terraform destroy
```

Terraform shows the destroy plan:
```
Plan: 0 to add, 0 to change, 1 to destroy.

  # aws_instance.web will be destroyed
  - resource "aws_instance" "web" {
      - ami           = "ami-0xxxxxxxx"
      - instance_type = "t2.micro"
      ...
    }
```

Type `yes` to confirm. After ~1 minute:
```
Destroy complete! Resources: 0 destroyed.
```

Verify in the AWS Console: instance state should be **Terminated**.

After destroy, `terraform.tfstate` will be nearly empty (just metadata). The `.terraform/` directory and `.terraform.lock.hcl` can remain — they don't incur any charges.

### Verify AWS Resources Are Gone

```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected output: empty (no instances running)
```

---

## 11. Key Concepts and Design Decisions

### Why Terraform Instead of AWS Console?

| Concern | AWS Console | Terraform |
|---|---|---|
| Repeatability | Manual steps, error-prone | Identical result every time |
| Review & approval | No diff — changes are immediate | `plan` shows exact changes before they happen |
| History | No record of what was changed | Version-controlled `.tf` files |
| Disaster recovery | Rebuild from memory | `terraform apply` — infrastructure in minutes |
| Drift detection | Not possible | `terraform plan` shows any drift from expected state |
| Team collaboration | Multiple people clicking | PR review of code changes |

### Why `required_version = ">= 1.5.0"`?

Terraform's HCL language and resource schemas evolve between major versions. Pinning `>= 1.5.0` prevents surprises when someone with Terraform 1.3 tries to apply a configuration that uses 1.5+ features (like `check` blocks). It also ensures CI pipelines fail fast if an outdated Terraform is installed rather than silently mishandling the configuration.

### Why `version = "~> 5.0"` for the AWS Provider?

This is a pessimistic constraint operator:
- `~> 5.0` allows `5.0`, `5.1`, `5.2` ... `5.99` but **not** `6.0`
- It permits bug fixes and feature additions within the major version
- It prevents Terraform from automatically upgrading to a new major version that may have breaking changes (AWS provider v5 → v6 introduced breaking renames)

### Why Ubuntu 22.04 LTS?

- **LTS (Long-Term Support):** Security updates until April 2027 — suitable for production
- **Standard base:** Most Terraform AWS tutorials, official HashiCorp examples, and AWS documentation reference Ubuntu
- **Canonical owner ID `099720109477`:** Using the owner filter ensures the AMI is published by Canonical, not a third party that might have modified the image

### The `.terraform.lock.hcl` File

This file is generated by `terraform init` and records the exact version of every provider installed. It should be **committed to version control**. Without it:
- A new team member running `terraform init` might get `aws = 5.75.0` while you have `5.50.0`
- A subtle provider regression could silently break your infrastructure

To upgrade providers intentionally:
```bash
terraform init -upgrade    # updates .terraform.lock.hcl to latest allowed versions
```

### What `terraform.tfstate` Contains — and Why Not to Edit It

The state file is a JSON document Terraform uses as its memory. It maps each resource in your `.tf` files to a real AWS resource ID. After `apply`, it contains the EC2 instance ID, IP, AMI, all computed attributes, and a schema version.

Rules:
1. **Never edit it manually** — if the JSON structure is invalid, Terraform cannot read state and all resource management breaks
2. **Never delete it before `terraform destroy`** — without state, Terraform cannot know what to delete and will orphan the EC2 instance (it keeps running and billing)
3. **Never commit it to version control** — it can contain sensitive values (passwords, keys) and will cause conflicts in team scenarios
4. Remote state (S3 + DynamoDB) solves the team problem — introduced in Lesson 03

---

## 12. Common Errors and Fixes

### `Error: No valid credential sources found`

```
Error: No valid credential sources found for AWS Provider
```

**Cause:** AWS CLI is not configured or credentials have expired.

**Fix:**
```bash
aws configure                         # re-enter your credentials
aws sts get-caller-identity           # confirm they work
```

### `Error: InvalidKeyPair.NotFound`

```
Error: Error launching source instance: InvalidKeyPair.NotFound: The key pair 'sarowar-ostad-mumbai' does not exist
```

**Cause:** The key pair referenced by `key_name` does not exist in this region.

**Fix (option A):** Create it in the AWS Console → EC2 → Key Pairs → Create key pair.

**Fix (option B):** Change `key_name` in `terraform.tfvars` to an existing key pair name.

**Fix (option C):** Remove the `key_name` line from `aws_instance.web` in `main.tf` — it is optional for an instance with no SSH access.

### `Error: InvalidAMIID.NotFound`

```
Error: Error launching source instance: InvalidAMIID.NotFound
```

**Cause:** The `data "aws_ami"` lookup returned an AMI that has since been deregistered (rare). More commonly, this means `aws_region` is incorrect and the data source is querying the wrong region's API.

**Fix:** Confirm `aws_region = "ap-south-1"` in `terraform.tfvars` and re-run `terraform init` if you changed regions (the provider must be re-initialized).

### `Error: Error acquiring the state lock`

```
Error: Error acquiring the state lock
  Lock Info:
    ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Cause (local state):** A previous `terraform apply` or `plan` was interrupted and left a `.terraform.tfstate.lock.info` file. This file acts as a lock to prevent concurrent operations.

**Fix:** If you are certain no other Terraform process is running:
```bash
terraform force-unlock <LOCK_ID>
```

Replace `<LOCK_ID>` with the ID shown in the error message.

### `terraform plan` Shows No Changes After First `apply`

This is correct and expected behaviour. Terraform compares the desired state (`.tf` files) against the current state (`terraform.tfstate`) and finds no differences. No changes are needed.

```
No changes. Your infrastructure matches the configuration.
```

### State File is Empty or Missing After `apply`

If `terraform.tfstate` is missing or empty, Terraform will try to create all resources from scratch on the next `apply`, resulting in duplicate EC2 instances.

**If this happens during the lesson:**
1. Go to the AWS Console and terminate any orphaned instances manually
2. Delete `terraform.tfstate` if it is corrupted
3. Re-run `terraform apply` to create a fresh instance with a new state file

---

## 13. What Comes Next

This lesson covered Terraform's most fundamental workflow. Here is how the subsequent lessons build on these concepts:

| Lesson | Adds On Top of This Lesson |
|---|---|
| **02 — AWS Basics** | Security groups, `locals` block, `default_tags`, inline `user_data` script |
| **03 — State Management** | Remote state in S3 + DynamoDB locking, `terraform state` commands, `terraform import` |
| **04 — Modules** | Refactoring repeated blocks into reusable modules, module inputs and outputs |
| **05 — Networking VPC** | Replace default VPC with a custom VPC, subnets, Internet Gateway, NAT Gateway |
| **06 — EC2 Deployment** | Automate the full Module 4 app stack: PostgreSQL + Node.js + React on one EC2 via `user_data` |
| **07 — RDS Database** | Extract database to managed RDS, introduce AWS Secrets Manager for credentials |
| **08–09 — 3-Tier** | Split into frontend/backend/database tiers, introduce ALB and HTTPS |
| **10–13** | Security hardening, automation depth, complete production deployment |

---

## Dependency Map

This lesson has the simplest possible dependency graph:

```
terraform.tfvars
      |
      v
variables.tf  <--------- main.tf reads var.*
      |                       |
      |               data.aws_ami.ubuntu
      |                       |
      |               aws_instance.web
      |                       |
      v                       v
outputs.tf  <---------- aws_instance.web.*
                         data.aws_ami.ubuntu.*
```

There are no module dependencies, no inter-resource dependencies beyond the data source, and no remote state. This is the simplest Terraform configuration structure possible.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
