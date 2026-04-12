# 03 — State Management

> **Course Position:** Lesson 03 of 13 — Module 8, Section 3: Remote State and Collaboration
> **Objective:** Migrate Terraform state from a local file to a shared, encrypted, version-controlled S3 bucket with DynamoDB locking — enabling safe team collaboration and state history.

This lesson has a **two-phase structure** that is unlike any other lesson:

1. **Phase 1 — Bootstrap** (`bootstrap/`): Run once to create the S3 bucket and DynamoDB table that will store all future Terraform state.
2. **Phase 2 — Remote State** (`main.tf`): Uncomment the `backend "s3"` block, re-run `terraform init`, and watch Terraform migrate local state to S3 automatically.

**Do not skip Phase 1.** Running Phase 2 without the S3 bucket existing will cause an immediate error.

---

## Table of Contents

1. [What This Lesson Does](#1-what-this-lesson-does)
2. [Technology Stack](#2-technology-stack)
3. [Architecture](#3-architecture)
4. [Folder Structure and File Reference](#4-folder-structure-and-file-reference)
5. [Prerequisites](#5-prerequisites)
6. [Phase 1 — Bootstrap Remote State Infrastructure](#6-phase-1--bootstrap-remote-state-infrastructure)
7. [Phase 2 — Enable Remote Backend](#7-phase-2--enable-remote-backend)
8. [Verifying Remote State](#8-verifying-remote-state)
9. [Understanding the Code](#9-understanding-the-code)
10. [Terraform State Operations Reference](#10-terraform-state-operations-reference)
11. [Making Changes Safely](#11-making-changes-safely)
12. [Cleanup](#12-cleanup)
13. [Key Concepts and Design Decisions](#13-key-concepts-and-design-decisions)
14. [Common Errors and Fixes](#14-common-errors-and-fixes)
15. [What Comes Next](#15-what-comes-next)

---

## 1. What This Lesson Does

This lesson demonstrates the evolution from local state (fine for solo learning) to remote state (required for team use or any serious deployment). A single demo EC2 instance serves as the managed resource — it is intentionally simple so attention stays on state behaviour, not infrastructure.

| New Concept | Where You See It |
|---|---|
| Remote state backend (`backend "s3"`) | `main.tf` — commented block, uncommented in Phase 2 |
| S3 bucket with versioning + encryption | `bootstrap/main.tf` |
| DynamoDB state locking | `bootstrap/main.tf` |
| `prevent_destroy = true` lifecycle | `bootstrap/main.tf` — protects state infrastructure |
| State migration (`terraform init` with existing state) | Phase 2 Step 3 — `init` prompts to copy local → S3 |
| `terraform state` subcommands | Section 10 — `list`, `show`, `pull`, `mv`, `rm` |
| Bootstrap pattern (chicken-and-egg) | Why bootstrap uses local state, all others use remote |

**What this lesson deliberately excludes** (covered in later lessons):

- Security groups (EC2 in default VPC, no open ports — focus is entirely on state)
- Custom VPC (Lesson 05)
- Modules (Lesson 04)

---

## 2. Technology Stack

### Tools Required on Your Machine

| Tool | Minimum Version | Purpose | Install |
|---|---|---|---|
| Terraform | 1.5.0 | Infrastructure provisioning | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | Verify state objects in S3 and DynamoDB | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

### AWS Services Created by This Lesson

| Phase | Service | Resource Name | Purpose |
|---|---|---|---|
| Bootstrap | S3 Bucket | `terraform-state-bmi-ostaddevops` | Stores all Terraform state files |
| Bootstrap | S3 Versioning | (on bucket above) | Retains every state version — enables rollback |
| Bootstrap | S3 Encryption | AES256 (SSE-S3) | State files are encrypted at rest |
| Bootstrap | S3 Public Access Block | (on bucket above) | Prevents state from ever being public |
| Bootstrap | DynamoDB Table | `terraform-state-lock` | One row per active `terraform apply` — prevents concurrent runs |
| Main lesson | EC2 Instance | `state-management-demo` | Demo resource whose state lives in S3 |

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

Both `bootstrap/main.tf` and the root `main.tf` use the same provider version constraint.

---

## 3. Architecture

### Bootstrap Infrastructure (Phase 1)

```
Your Machine
      |
      | terraform apply (bootstrap/)
      v
AWS ap-south-1
      |
      +-- S3 Bucket: terraform-state-bmi-ostaddevops
      |       Versioning:   Enabled  (every state version kept forever)
      |       Encryption:   AES256 SSE-S3 (at rest)
      |       Public access: BLOCKED on all 4 dimensions
      |       prevent_destroy = true (Terraform refuses to delete it)
      |
      +-- DynamoDB Table: terraform-state-lock
              Billing:  PAY_PER_REQUEST (no standing cost)
              Hash key: LockID (string)
              prevent_destroy is NOT set (table can be destroyed)
```

### Remote State Layout (Phase 2)

```
S3 Bucket: terraform-state-bmi-ostaddevops
      |
      +-- lessons/
      |     +-- 03-state-management/
      |           +-- terraform.tfstate          <- main lesson state
      |
      +-- (future lessons add more keys here)
      +-- dev/terraform.tfstate                  <- environments/dev (Lesson 08+)
      +-- staging/terraform.tfstate
      +-- prod/terraform.tfstate
```

### Bootstrap Owns Itself (Local State)

```
bootstrap/
      |-- main.tf     (uses local state — no backend block)
      |-- terraform.tfstate   (auto-generated — tracks the S3 bucket + DynamoDB)

main.tf  (uses remote state — backend "s3" block after Phase 2)
      |
      S3: terraform-state-bmi-ostaddevops/lessons/03-state-management/terraform.tfstate
```

The bootstrap workdir has its own local state that tracks the S3 bucket and DynamoDB table. The main workdir's state is stored remotely in that same S3 bucket.

### DynamoDB Locking — How It Works

```
Engineer A: terraform apply
     |
     +-- Writes lock row to DynamoDB: { LockID: "bucket/key/terraform.tfstate", Info: {...} }
     |
     +-- EC2 created
     |
     +-- Deletes lock row from DynamoDB

Engineer B (during A's apply):
     |
     +-- Tries to write lock row -- DynamoDB conditional put FAILS (row exists)
     +-- Error: "Error acquiring the state lock" -- apply blocked
```

---

## 4. Folder Structure and File Reference

```
03-state-management/
|-- bootstrap/
|   +-- main.tf                 Phase 1: creates S3 bucket + DynamoDB (local state)
|
|-- main.tf                     Phase 2: demo EC2 with S3 backend (remote state)
|-- variables.tf                2 variables: aws_region, key_name
|-- outputs.tf                  2 outputs: instance_id, public_ip
|-- terraform.tfvars.example    Template -- copy to terraform.tfvars
|-- README.md                   This file
|
|-- (auto-generated)
|-- .terraform/                 Provider binaries (root workspace)
|-- .terraform.lock.hcl         Provider lock (root workspace)
|-- terraform.tfstate           Local state (only exists BEFORE Phase 2)
```

### File-by-File Explanation

#### `bootstrap/main.tf`

The only file in the bootstrap subdirectory. It is a standalone, complete Terraform configuration with its own provider, resources, and outputs — no `variables.tf` or `terraform.tfvars` needed because the bucket name and region are fixed for this course.

Key resources and why they are configured as they are:

**S3 Bucket — `aws_s3_bucket.terraform_state`:**
```hcl
lifecycle {
  prevent_destroy = true
}
```
`prevent_destroy = true` causes `terraform destroy` to fail with a clear error if someone tries to delete this resource through Terraform. This is a safety net — the state bucket is irreplaceable infrastructure. If the bucket is deleted, all state for every environment is gone and manual reconstruction is required.

**S3 Versioning — `aws_s3_bucket_versioning.terraform_state`:**
```hcl
versioning_configuration {
  status = "Enabled"
}
```
Every `terraform apply` that changes state writes a new object version. If a bad apply corrupts state, you can download the previous version from S3. Without versioning, the previous state is overwritten and unrecoverable.

**S3 Server-Side Encryption:**
```hcl
sse_algorithm = "AES256"
```
State files frequently contain sensitive values (IP addresses, ARNs, and in some configurations, passwords). AES256 SSE-S3 encrypts every object at rest automatically. No key management required — AWS manages the key. For stricter requirements, use `aws:kms` with a customer-managed key.

**S3 Public Access Block:**
```hcl
block_public_acls       = true
block_public_policy     = true
ignore_public_acls      = true
restrict_public_buckets = true
```
All four dimensions of public access are blocked. A misconfigured bucket policy or ACL cannot accidentally expose state files. This is defense-in-depth — even if someone adds a public bucket policy, these flags override it.

**DynamoDB Table — `aws_dynamodb_table.terraform_lock`:**
```hcl
billing_mode = "PAY_PER_REQUEST"
hash_key     = "LockID"
```
`PAY_PER_REQUEST` means there is no hourly cost for the table — you are only charged per read/write operation. For a state lock table that sees a few operations per `terraform apply`, this is essentially free (fractions of a cent per month). The `LockID` attribute stores the S3 path of the locked state file.

**Bootstrap Outputs:**
```
state_bucket_name  = "terraform-state-bmi-ostaddevops"
dynamodb_table_name = "terraform-state-lock"
next_step          = "Go back to 03-state-management/, uncomment the backend block in main.tf, then run: terraform init"
```
The `next_step` output acts as an in-terminal guide — after `apply` completes, the user sees exactly what to do next.

#### `main.tf` — The Backend Block

```hcl
# STEP 2: Uncomment after running bootstrap/
# backend "s3" {
#   bucket         = "terraform-state-bmi-ostaddevops"
#   key            = "lessons/03-state-management/terraform.tfstate"
#   region         = "ap-south-1"
#   dynamodb_table = "terraform-state-lock"
#   encrypt        = true
# }
```

**Why it starts commented out:**
Before bootstrap runs, the S3 bucket does not exist. If the backend block were active, `terraform init` would try to connect to a non-existent bucket and fail immediately. The commented-out pattern teaches the correct sequence: create the bucket first, then point the backend at it.

**Backend block attributes:**
- `bucket` — the S3 bucket name (must already exist)
- `key` — the S3 object path where this workspace's state is stored
- `region` — the AWS region of the bucket (independent of where resources are deployed)
- `dynamodb_table` — the DynamoDB table for locking (must be in the same region as the bucket)
- `encrypt = true` — enables client-side encryption in addition to the bucket's server-side encryption

**The demo EC2 instance:**
```hcl
resource "aws_instance" "demo" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  tags = {
    Name      = "state-management-demo"
    ManagedBy = "terraform"
  }
}
```
This intentionally simple resource exists purely to give the state file something to track. No SG, no EIP — the focus is on what happens to the state file, not to the instance.

#### `variables.tf`

Two variables, both with defaults — `aws_region` (`ap-south-1`) and `key_name` (`sarowar-ostad-mumbai`). No required variables in this lesson.

#### `outputs.tf`

`instance_id` and `public_ip`. These outputs exist to show that outputs work identically with both local and remote state — the `terraform output` command fetches from wherever the backend is configured.

---

## 5. Prerequisites

### Terraform and AWS CLI

See [Lesson 01, Section 5](../01-terraform-fundamentals/README.md) for full installation instructions.

Quick check:
```bash
terraform version       # must be >= 1.5.0
aws sts get-caller-identity   # must return your account ID
```

### IAM Permissions Required

This lesson creates more AWS resources than previous ones. Your user or role needs:

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:CreateBucket",
    "s3:DeleteBucket",
    "s3:PutBucketVersioning",
    "s3:PutEncryptionConfiguration",
    "s3:PutBucketPublicAccessBlock",
    "s3:GetBucketVersioning",
    "s3:GetEncryptionConfiguration",
    "s3:GetBucketPublicAccessBlock",
    "s3:ListBucket",
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",
    "dynamodb:CreateTable",
    "dynamodb:DeleteTable",
    "dynamodb:DescribeTable",
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:DeleteItem",
    "ec2:DescribeImages",
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

## 6. Phase 1 — Bootstrap Remote State Infrastructure

**Run this phase exactly once per AWS account.** If someone on your team has already run it, skip to Phase 2.

### Step 1: Navigate to the Bootstrap Directory

```bash
cd 03-state-management/bootstrap
```

This is a separate Terraform workspace from the parent directory. It has its own `.terraform/` and its own state file.

### Step 2: Initialize Bootstrap

```bash
terraform init
```

Expected last line:
```
Terraform has been successfully initialized!
```

### Step 3: Review the Bootstrap Plan

```bash
terraform plan
```

You should see **5 resources to add**:
- `aws_s3_bucket.terraform_state`
- `aws_s3_bucket_versioning.terraform_state`
- `aws_s3_bucket_server_side_encryption_configuration.terraform_state`
- `aws_s3_bucket_public_access_block.terraform_state`
- `aws_dynamodb_table.terraform_lock`

### Step 4: Apply Bootstrap

```bash
terraform apply
```

Type `yes`. Takes approximately 15–30 seconds.

Expected output after apply:
```
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

dynamodb_table_name = "terraform-state-lock"
next_step           = "Go back to 03-state-management/, uncomment the backend block in main.tf, then run: terraform init"
state_bucket_name   = "terraform-state-bmi-ostaddevops"
```

### Step 5: Verify the S3 Bucket

```bash
aws s3api get-bucket-versioning \
  --bucket terraform-state-bmi-ostaddevops \
  --region ap-south-1
# Expected: {"Status": "Enabled"}

aws s3api get-bucket-encryption \
  --bucket terraform-state-bmi-ostaddevops \
  --region ap-south-1
# Expected: SSEAlgorithm: AES256

aws s3api get-public-access-block \
  --bucket terraform-state-bmi-ostaddevops \
  --region ap-south-1
# Expected: all 4 values = true
```

### Step 6: Verify the DynamoDB Table

```bash
aws dynamodb describe-table \
  --table-name terraform-state-lock \
  --region ap-south-1 \
  --query "Table.{Status:TableStatus,Billing:BillingModeSummary.BillingMode}" \
  --output table
# Expected: ACTIVE, PAY_PER_REQUEST
```

### What Gets Committed

The bootstrap workspace generates a local `terraform.tfstate` in `bootstrap/`. **Do not delete this file.** It is how Terraform knows the S3 bucket and DynamoDB table exist — if you want to modify or destroy the bootstrap resources later, you need this state.

The `.gitignore` in the repo root already blocks `*.tfstate`. Bootstrap state stays local on the machine that ran it. This is acceptable because:
1. Bootstrap resources are extremely rarely modified
2. Putting the bootstrap state in a remote backend would require a separate remote backend (circular dependency)

---

## 7. Phase 2 — Enable Remote Backend

### Step 1: Return to the Main Lesson Directory

```bash
cd ..   # from bootstrap/ back to 03-state-management/
# or from the repo root:
cd 03-state-management
```

### Step 2: First Apply with Local State (Optional but Recommended)

Run `terraform apply` once with the local backend before migrating. This creates the EC2 instance and writes `terraform.tfstate` locally, giving you something to migrate in Step 4.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Expected output:
```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:
instance_id = "i-0xxxxxxxxxxxxxxxx"
public_ip   = "x.x.x.x"
```

You can now see `terraform.tfstate` exists locally:
```bash
cat terraform.tfstate   # raw JSON — note the instance ID
```

### Step 3: Uncomment the Backend Block

Open `main.tf` and remove the comment characters from the backend block:

**Before:**
```hcl
  # backend "s3" {
  #   bucket         = "terraform-state-bmi-ostaddevops"
  #   key            = "lessons/03-state-management/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
```

**After:**
```hcl
  backend "s3" {
    bucket         = "terraform-state-bmi-ostaddevops"
    key            = "lessons/03-state-management/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
```

Save the file.

### Step 4: Re-Initialize with State Migration

```bash
terraform init
```

Because you changed the backend configuration, Terraform detects the change and asks if you want to copy the existing local state to S3:

```
Initializing the backend...
Do you want to copy existing state to the new backend?
  Pre-existing state was found while migrating the previous "local" backend to the
  newly configured "s3" backend. No existing state was found in the newly configured
  "s3" backend. Do you want to copy this state to the new backend?

  Enter a value: yes
```

Type `yes`. Terraform copies the local state to S3.

Expected completion:
```
Successfully configured the backend "s3"! Terraform will automatically
use this backend unless the backend configuration changes.
```

### Step 5: Confirm State is in S3

```bash
# List the state file in S3
aws s3 ls s3://terraform-state-bmi-ostaddevops/lessons/03-state-management/
# Expected: terraform.tfstate (dated today)

# Download and inspect the remote state
aws s3 cp s3://terraform-state-bmi-ostaddevops/lessons/03-state-management/terraform.tfstate - | python3 -m json.tool | head -30
```

### Step 6: Verify Local State is No Longer Used

After migration, the local `terraform.tfstate` file remains but Terraform ignores it (the backend is now S3). Confirm:

```bash
terraform state list
# Returns: aws_instance.demo
# This came from S3, not the local file
```

Run a plan to confirm nothing changed during migration:
```bash
terraform plan
# Expected: No changes. Your infrastructure matches the configuration.
```

---

## 8. Verifying Remote State

### Check the State File in S3

```bash
# List all state files
aws s3 ls s3://terraform-state-bmi-ostaddevops/ --recursive

# Download state to inspect
terraform state pull
# Prints the full state JSON to stdout — useful for debugging
```

### Check DynamoDB (Should Be Empty When Not Locked)

```bash
aws dynamodb scan \
  --table-name terraform-state-lock \
  --region ap-south-1
# Expected: {"Count": 0, "Items": []}  (no active locks)
```

### Observe DynamoDB Locking in Real Time

Run `terraform apply` in one terminal and immediately check DynamoDB in a second terminal:

**Terminal 1:**
```bash
terraform apply
# (leave it running)
```

**Terminal 2 (while Terminal 1 is running):**
```bash
aws dynamodb scan \
  --table-name terraform-state-lock \
  --region ap-south-1 \
  --query "Items[].LockID"
# Expected while apply is running:
# ["terraform-state-bmi-ostaddevops/lessons/03-state-management/terraform.tfstate"]
```

After Terminal 1 completes, Terminal 2 scan shows `Count: 0` — the lock is released.

### View State Version History

```bash
# List all versions of the state file
aws s3api list-object-versions \
  --bucket terraform-state-bmi-ostaddevops \
  --prefix lessons/03-state-management/terraform.tfstate \
  --query "Versions[].{Version:VersionId,Modified:LastModified,Size:Size}" \
  --output table
```

Each `terraform apply` that changes resources adds a new version. This is your state history.

---

## 9. Understanding the Code

### Why Bootstrap Uses Local State

The bootstrap configuration cannot use a remote S3 backend because it is creating the S3 bucket that the backend would point to. This is the classic "chicken-and-egg" problem:

```
Remote state backend requires: S3 bucket exists
S3 bucket creation requires:   terraform apply to run
terraform apply requires:       backend to be initialized

Solution: bootstrap uses local state to create S3 bucket,
          all subsequent configs use S3 backend
```

This is the standard industry pattern for Terraform bootstrapping.

### Why `prevent_destroy = true` on the S3 Bucket

```hcl
lifecycle {
  prevent_destroy = true
}
```

If someone accidentally runs `terraform destroy` in the `bootstrap/` directory, this lifecycle rule causes Terraform to stop with an error:

```
Error: Instance cannot be destroyed

  on main.tf line 25, in resource "aws_s3_bucket" "terraform_state":
  25:   lifecycle {

This object has lifecycle.prevent_destroy set to true. To allow this resource
to be destroyed, remove the lifecycle entry or set prevent_destroy to false.
```

The S3 bucket holds the state for all environments and all lessons. Accidental deletion is catastrophic — you lose track of every resource Terraform manages and must reconcile manually or accept duplicate infrastructure.

### The S3 Backend — Every Attribute Explained

```hcl
backend "s3" {
  bucket         = "terraform-state-bmi-ostaddevops"  # bucket name (must exist)
  key            = "lessons/03-state-management/terraform.tfstate"  # object path
  region         = "ap-south-1"                       # bucket region
  dynamodb_table = "terraform-state-lock"             # lock table name
  encrypt        = true                               # encrypt state at rest
}
```

The `key` is the S3 object path. By convention, different workspaces use different keys:
```
lessons/01-terraform-fundamentals/terraform.tfstate
lessons/02-terraform-aws-basics/terraform.tfstate
lessons/03-state-management/terraform.tfstate
dev/terraform.tfstate
staging/terraform.tfstate
prod/terraform.tfstate
```

All keys land in the same bucket, isolated by path. Two workspaces with the same key would share state — always use unique keys per workspace.

### Why `encrypt = true` in Addition to Bucket Encryption

The bucket has AES256 SSE-S3 (server-side encryption). The `encrypt = true` in the backend block additionally encrypts the HTTP request body in transit to S3 (enforces HTTPS). Both settings together satisfy most security compliance requirements.

### `PAY_PER_REQUEST` Billing for DynamoDB

The state lock table sees roughly 2–4 DynamoDB operations per `terraform apply` (write lock, read lock, delete lock). At AWS pricing, this costs approximately $0.000025 per operation — a busy team running 50 applies per day spends about $0.004 daily on locking. `PAY_PER_REQUEST` avoids the minimum $0.65/hour cost of provisioned capacity for a table that is mostly idle.

---

## 10. Terraform State Operations Reference

These commands work once remote state is configured. All read/write from S3.

### Inspect State

```bash
# List all resources in state
terraform state list

# Show all attributes of a specific resource
terraform state show aws_instance.demo

# Pull the full state (JSON) to stdout
terraform state pull

# Save state to a local file for inspection or backup
terraform state pull > state-backup.json
```

### Understand Drift

```bash
# Refresh state against real AWS — updates state to match current AWS attributes
terraform refresh

# Show what would change (same as plan but shows drift from state vs config)
terraform plan
```

### Move Resources in State

```bash
# Rename a resource in state (e.g., after refactoring in main.tf)
terraform state mv aws_instance.demo aws_instance.web

# Move a resource into a module
terraform state mv aws_instance.demo module.ec2.aws_instance.this
```

### Remove Resources from State

```bash
# Remove a resource from state WITHOUT destroying it in AWS
# Use when you want Terraform to "forget" a resource (e.g., manually created resource you want to keep)
terraform state rm aws_instance.demo
```

### Import Existing Resources

```bash
# Bring an existing AWS resource under Terraform management
# Syntax: terraform import <resource_address> <aws_resource_id>
terraform import aws_instance.demo i-0xxxxxxxxxxxxxxxx
```

After import, run `terraform plan` — Terraform may show differences between the imported resource's actual config and what is in `main.tf`. Update `main.tf` to match until `plan` shows no changes.

### Recover from State Corruption

If `terraform state pull` returns invalid JSON or Terraform reports state errors:

```bash
# Step 1: List versions in S3
aws s3api list-object-versions \
  --bucket terraform-state-bmi-ostaddevops \
  --prefix lessons/03-state-management/terraform.tfstate \
  --query "Versions[*].{VersionId:VersionId,Date:LastModified}" \
  --output table

# Step 2: Download a previous known-good version
aws s3api get-object \
  --bucket terraform-state-bmi-ostaddevops \
  --key lessons/03-state-management/terraform.tfstate \
  --version-id <VERSION_ID> \
  previous-good.tfstate

# Step 3: Inspect it
cat previous-good.tfstate | python3 -m json.tool | head -20

# Step 4: Push the recovered state back (use with extreme caution)
terraform state push previous-good.tfstate
```

---

## 11. Making Changes Safely

### Change the Instance Type

```bash
# main.tf — change instance_type:
resource "aws_instance" "demo" {
  instance_type = "t3.micro"   # was t2.micro
```

```bash
terraform plan   # shows -/+ replacement (instance type change forces new instance)
terraform apply
```

### View State After Apply

```bash
# Confirm new instance ID is in remote state
terraform state show aws_instance.demo

# Confirm a new state version was written to S3
aws s3api list-object-versions \
  --bucket terraform-state-bmi-ostaddevops \
  --prefix lessons/03-state-management/terraform.tfstate \
  --query "Versions | length(@)"
# Should increment by 1 after each apply that changes resources
```

### Simulate a Second Engineer (Locking Test)

In the same directory, open two terminals and run `terraform apply` simultaneously:

**Terminal 1:** `terraform apply` (runs normally)

**Terminal 2 (immediately after Terminal 1):**
```bash
terraform apply
# Expected error:
# Error: Error acquiring the state lock
# Lock Info:
#   ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   Path:      terraform-state-bmi-ostaddevops/lessons/03-state-management/terraform.tfstate
#   Operation: OperationTypeApply
#   Who:       user@machine
#   Created:   2026-04-12 ...
```

This confirms locking is working correctly. Terminal 2 is blocked until Terminal 1 releases the lock.

---

## 12. Cleanup

Cleanup is a two-phase process, mirroring deployment.

### Phase 2 Cleanup — Destroy the Demo EC2

From `03-state-management/`:
```bash
terraform destroy
```

Type `yes`. This deletes the EC2 instance and removes the state file from S3 (the state file itself remains in S3 but is now empty).

Verify the instance is gone:
```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Name,Values=state-management-demo" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected: empty
```

### Phase 1 Cleanup — Destroy Bootstrap Resources

**WARNING: Only do this if you are completely done with the entire repository.** Destroying the S3 bucket and DynamoDB table removes the remote state infrastructure that later lessons (05–13) depend on.

Because `prevent_destroy = true` is set on the S3 bucket, you must first disable it. Edit `bootstrap/main.tf`:

```hcl
# Remove or change prevent_destroy before destroying
lifecycle {
  prevent_destroy = false   # changed from true
}
```

Then:
```bash
cd bootstrap

# The S3 bucket must be empty before it can be deleted
# (Terraform does not automatically empty versioned buckets)

# Delete all object versions first:
aws s3api delete-objects \
  --bucket terraform-state-bmi-ostaddevops \
  --delete "$(aws s3api list-object-versions \
    --bucket terraform-state-bmi-ostaddevops \
    --output json \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"

# Delete all delete markers:
aws s3api delete-objects \
  --bucket terraform-state-bmi-ostaddevops \
  --delete "$(aws s3api list-object-versions \
    --bucket terraform-state-bmi-ostaddevops \
    --output json \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')"

# Now destroy
terraform destroy
```

---

## 13. Key Concepts and Design Decisions

### Why Remote State at All?

| Problem | Local State | Remote State (S3) |
|---|---|---|
| Two engineers apply simultaneously | Both write conflicting state files | DynamoDB lock prevents second apply |
| Engineer's laptop dies | State lost — impossible to manage resources | State safe in S3 |
| "What does Terraform think exists?" | Check local file | Any machine with credentials can pull state |
| State history / rollback | None (file overwritten each apply) | S3 versioning keeps every state version |
| CI/CD pipeline apply | Impossible without state on machine | Pipeline downloads state from S3 automatically |
| State contains passwords | Plaintext in committed file | Encrypted in S3, not in version control |

### Why a Separate `bootstrap/` Directory?

The most common alternative is to create the S3 bucket and DynamoDB table manually in the AWS Console. That approach works but is error-prone (naming typos, versioning forgotten, encryption skipped) and is not reproducible. The `bootstrap/` pattern makes the state infrastructure itself defined as code while solving the circular dependency.

### Why Not Use Terraform Cloud or HCP Terraform?

Terraform Cloud (now HCP Terraform) provides managed remote state with no bootstrapping required. This lesson uses S3 + DynamoDB because:
1. It is the most widely used pattern in industry (no vendor dependency)
2. It works with any AWS account without additional accounts/sign-ups
3. The implementation details (versioning, encryption, locking) are educational in themselves
4. Cost: essentially free at this scale

### State File Security

The state file may contain:
- EC2 instance IDs, private IP addresses
- Security group IDs and rules
- In later lessons: IAM role ARNs, database endpoints

It does NOT contain:
- AWS credentials (those are in `~/.aws/credentials`)
- In this course: passwords (Secrets Manager handles that from Lesson 07+)

Best practices applied here:
- S3 bucket is private (public access blocked)
- AES256 encryption at rest
- `encrypt = true` in backend (HTTPS in transit)
- `.gitignore` blocks `*.tfstate` — state never enters version control

---

## 14. Common Errors and Fixes

### `Error: Failed to get existing workspaces: S3 bucket does not exist`

```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

**Cause:** You uncommented the backend block and ran `terraform init` before running the bootstrap.

**Fix:**
```bash
cd bootstrap
terraform init && terraform apply
cd ..
terraform init
```

### `Error: BucketAlreadyOwnedByYou`

```
Error: creating S3 Bucket: BucketAlreadyOwnedByYou: Your previous request to create the named bucket succeeded
```

**Cause:** Bootstrap was already run — the bucket already exists in your account.

**Fix:** This is safe. Skip bootstrap and proceed directly to Phase 2. Or apply specific targets only:
```bash
terraform apply -target=aws_dynamodb_table.terraform_lock
```

### `Error: Instance cannot be destroyed` (prevent_destroy)

```
Error: Instance cannot be destroyed
...
This object has lifecycle.prevent_destroy set to true.
```

**Cause:** Attempting `terraform destroy` in `bootstrap/` with `prevent_destroy = true` still set.

**Fix:** Edit `bootstrap/main.tf`, change `prevent_destroy = false`, then retry destroy. Also empty the S3 bucket first (see [Cleanup, Phase 1](#phase-1-cleanup--destroy-bootstrap-resources)).

### `Error: Error acquiring the state lock`

```
Error: Error acquiring the state lock

  Lock Info:
    ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Cause A:** Another `terraform apply` or `plan` is genuinely running (expected behavior — wait for it to finish).

**Cause B:** A previous apply was killed (Ctrl+C, crash, network loss) and left a stale lock in DynamoDB.

**Fix for stale lock:**
```bash
terraform force-unlock <LOCK_ID>
# Replace <LOCK_ID> with the UUID from the error message
```

Use `force-unlock` only when you are certain no other process is running. Unlocking during an active apply can corrupt state.

### `terraform init` Does Not Ask to Migrate State

**Cause:** You ran `terraform apply` after uncommenting the backend but BEFORE running `terraform init`. Terraform defaults to the previous backend.

**Fix:**
```bash
terraform init -reconfigure
# -reconfigure forces re-reading the backend config
```

Or if you want migration:
```bash
terraform init -migrate-state
```

### After Migration, `terraform plan` Shows the Instance Will Be Re-Created

**Cause:** The instance ID in local state was not migrated correctly, and Terraform thinks the EC2 needs to be recreated.

**Fix:** Confirm the remote state has the correct instance ID:
```bash
terraform state show aws_instance.demo   # should show the existing instance ID
aws ec2 describe-instances --instance-ids <ID> --region ap-south-1   # confirm it exists
```

If state is truly missing the instance, import it:
```bash
terraform import aws_instance.demo <EXISTING_INSTANCE_ID>
```

---

## 15. What Comes Next

| Lesson | Builds on This Lesson |
|---|---|
| **04 — Modules** | Uses local state (simpler) — remote state concepts apply to team scenarios shown here |
| **08 — 3-Tier Basic (environments/dev)** | Uses S3 backend from this lesson's bootstrap, key `dev/terraform.tfstate` |
| **09 — 3-Tier Production (environments/prod)** | Same bucket, key `prod/terraform.tfstate` — multiple environments in one bucket |
| **13 — Complete Production** | Full remote state, all teams share one bucket, isolated by environment key |

The S3 bucket created in this lesson's bootstrap (`terraform-state-bmi-ostaddevops`) is referenced by every production environment deployment in this repository. Keep it running.

---

## Dependency Map

```
bootstrap/ workspace
      |
      +-- aws_s3_bucket.terraform_state
      |     lifecycle.prevent_destroy = true
      |
      +-- aws_s3_bucket_versioning          depends on: aws_s3_bucket
      +-- aws_s3_bucket_server_side_encryption  depends on: aws_s3_bucket
      +-- aws_s3_bucket_public_access_block depends on: aws_s3_bucket
      |
      +-- aws_dynamodb_table.terraform_lock (independent)


03-state-management/ workspace (after Phase 2)
      |
      +-- terraform backend "s3"
      |       bucket: terraform-state-bmi-ostaddevops  (created by bootstrap)
      |       table:  terraform-state-lock             (created by bootstrap)
      |
      +-- data.aws_ami.ubuntu      (read-only API call)
      |
      +-- aws_instance.demo        depends on: data.aws_ami.ubuntu.id
```

The cross-workspace dependency (main lesson → bootstrap resources) is **not tracked by Terraform** — it is an implicit dependency. This is why `prevent_destroy = true` exists: Terraform cannot automatically prevent you from destroying bootstrap resources that another workspace depends on.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
