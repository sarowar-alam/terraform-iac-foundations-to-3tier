# 04 — Terraform Modules

> **Course Position:** Lesson 04 of 13 — Module 8, Section 4: Reusable Infrastructure with Modules
> **Objective:** Refactor a monolithic EC2 + Security Group configuration into a reusable local module, and call that module from a root configuration — establishing the pattern used in every production Terraform codebase.

This lesson introduces the single most important structural concept in Terraform: the **module**. After this lesson, the BMI Health Tracker infrastructure is no longer written as a flat list of resources — it is composed from reusable, encapsulated components.

**Prerequisites:** Complete Lessons 01–03. Lesson 02 introduced EC2 + Security Group (this lesson refactors that exact pattern). Understanding `locals`, `data` sources, and the `terraform apply` workflow is assumed.

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

The same EC2 + Security Group infrastructure from Lesson 02 is deployed here — but structured as a module rather than inline resources. The root configuration (`main.tf`) contains **zero resource blocks**. Everything is delegated to `modules/webserver/`.

| New Concept | Where You See It |
|---|---|
| `module` block | `main.tf` — `module "web_server" { source = "./modules/webserver" }` |
| Module `source` path | `main.tf` — `source = "./modules/webserver"` |
| Module input variables | `main.tf` — all the key-value pairs inside `module "web_server" {}` |
| Module output chaining | `outputs.tf` — `value = module.web_server.instance_id` |
| Module-internal `data` source | `modules/webserver/main.tf` — `data "aws_ami"` inside the module |
| No `provider` in module | `modules/webserver/main.tf` has no `provider` block — inherits from root |
| Variable interpolation in `user_data` | `modules/webserver/main.tf` — `${var.project_name}` inside heredoc |
| Required module inputs (no default) | `modules/webserver/variables.tf` — `project_name`, `environment`, `vpc_id`, `allowed_ssh_cidr` |

**What this lesson deliberately excludes:**

- Remote state (Lesson 03). Local state only.
- Custom VPC (Lesson 05). Uses `data "aws_vpc" "default"`.
- Multiple module instances (calling the same module twice). The pattern is shown once.

---

## 2. Technology Stack

### Tools Required on Your Machine

| Tool | Minimum Version | Purpose | Install |
|---|---|---|---|
| Terraform | 1.5.0 | Infrastructure provisioning | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | Verification commands | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| SSH client | any | Connect to the EC2 instance | Pre-installed on macOS/Linux; OpenSSH on Windows 10+ |

### AWS Services Used

| Service | Resource | Where Defined |
|---|---|---|
| EC2 AMI (lookup) | `data "aws_ami" "ubuntu"` | `modules/webserver/main.tf` |
| VPC (lookup) | `data "aws_vpc" "default"` | `main.tf` (root) |
| EC2 Security Group | `aws_security_group.web` | `modules/webserver/main.tf` |
| EC2 Instance | `aws_instance.web` | `modules/webserver/main.tf` |

Two resources are created in AWS: one Security Group and one EC2 instance — identical to Lesson 02, but now encapsulated inside the module.

### Provider Configuration

The `provider "aws"` block lives only in the **root** `main.tf`. The module (`modules/webserver/main.tf`) has no provider block — it inherits the provider configuration from whoever calls it.

```hcl
# Root main.tf only
provider "aws" {
  region = var.aws_region
}
```

This is a fundamental rule: **modules must not contain provider configurations.** Provider configuration belongs to the root module.

---

## 3. Architecture

### Physical Infrastructure (Same as Lesson 02)

```
Your Machine (Terraform runs here)
        |
        | terraform apply
        v
AWS ap-south-1 — Default VPC
        |
        +-- aws_security_group.web  (bmi-health-tracker-dev-webserver-sg)
        |       Port 22  <- YOUR IP/32 (SSH)
        |       Port 80  <- 0.0.0.0/0 (HTTP public)
        |       All outbound -> 0.0.0.0/0
        |
        +-- aws_instance.web  (bmi-health-tracker-dev-webserver)
                Ubuntu 22.04 LTS, t2.micro
                user_data: installs Nginx, serves "bmi-health-tracker — Served from Module"
```

### Terraform Call Graph (New in This Lesson)

```
Root Module (04-modules/)
      |
      |  module "web_server" {
      |    source = "./modules/webserver"
      |    project_name     = var.project_name      --> "bmi-health-tracker"
      |    environment      = var.environment       --> "dev"
      |    vpc_id           = data.aws_vpc.default.id
      |    instance_type    = var.instance_type     --> "t2.micro"
      |    key_name         = var.key_name
      |    allowed_ssh_cidr = var.allowed_ssh_cidr  --> "YOUR_IP/32"
      |  }
      |
      v
Child Module (04-modules/modules/webserver/)
      |
      +-- data "aws_ami" "ubuntu"         (AMI lookup)
      +-- aws_security_group.web          (creates SG in AWS)
      +-- aws_instance.web                (creates EC2 in AWS)
      |
      outputs:
        instance_id -> aws_instance.web.id
        public_ip   -> aws_instance.web.public_ip
        ssh_command -> "ssh -i key.pem ubuntu@<ip>"
        app_url     -> "http://<ip>"
      |
      v  (outputs flow back up to root)
Root outputs:
      module.web_server.instance_id
      module.web_server.public_ip
      module.web_server.ssh_command
      module.web_server.app_url
```

### Module Boundary — Inputs and Outputs

```
Root Module
    |
    |  INPUT variables passed to module:
    |    project_name, environment, vpc_id,
    |    instance_type, key_name, allowed_ssh_cidr
    |
    v
 [  webserver MODULE  ]
 [                    ]
 [  data.aws_ami      ]
 [  aws_security_group]  <-- uses vpc_id, allowed_ssh_cidr, project_name, environment
 [  aws_instance      ]  <-- uses ami, instance_type, key_name, project_name
 [                    ]
    |
    |  OUTPUT values exposed by module:
    |    instance_id, public_ip, ssh_command, app_url
    v
Root Module reads: module.web_server.<output_name>
```

Everything inside the module boundary is implementation detail — the root module only sees declared inputs and outputs.

---

## 4. Folder Structure and File Reference

```
04-modules/
|-- main.tf                         Root config: provider + data source + module call
|-- variables.tf                    Root inputs: 6 variables (aws_region through allowed_ssh_cidr)
|-- outputs.tf                      Root outputs: 4 values delegated from module
|-- terraform.tfvars.example        Template — copy to terraform.tfvars
|-- README.md                       This file
|
+-- modules/
    +-- webserver/
        |-- main.tf                 Module: data source + SG + EC2 resource
        |-- variables.tf            Module inputs: 6 variables (some required)
        +-- outputs.tf              Module outputs: instance_id, public_ip, ssh_command, app_url
|
|-- (auto-generated)
|-- .terraform/                     Provider binaries + module link
|-- .terraform.lock.hcl             Provider version lock
+-- terraform.tfstate               Local state tracking both resources
```

### Root Files

#### `main.tf` (root)

```hcl
data "aws_vpc" "default" {
  default = true
}

module "web_server" {
  source = "./modules/webserver"

  project_name     = var.project_name
  environment      = var.environment
  vpc_id           = data.aws_vpc.default.id
  instance_type    = var.instance_type
  key_name         = var.key_name
  allowed_ssh_cidr = var.allowed_ssh_cidr
}
```

The root `main.tf` contains:
- One `data` source (VPC lookup — needed because `vpc_id` is a required module input)
- One `module` block (the webserver)
- Zero `resource` blocks directly

The `vpc_id` cannot be resolved inside the module without either hardcoding it or passing it in. Passing it in (as done here) makes the module portable — the same module could be called with a custom VPC ID in a later lesson simply by changing the input value.

#### `variables.tf` (root)

Six variables using compact single-line style (equivalent to the multi-line style used in other lessons — purely a formatting choice):

```hcl
variable "allowed_ssh_cidr" {
  type        = string
  description = "Your IP: x.x.x.x/32"
  # No default — required input
}
```

`allowed_ssh_cidr` has no default. If omitted from `terraform.tfvars`, Terraform prompts interactively.

#### `outputs.tf` (root)

```hcl
output "instance_id" { value = module.web_server.instance_id }
output "public_ip"   { value = module.web_server.public_ip }
output "ssh_command" { value = module.web_server.ssh_command }
output "app_url"     { value = module.web_server.app_url }
```

Every output references `module.web_server.<name>`. The root has no direct contact with `aws_instance.web` or `aws_security_group.web` — it only sees what the module exposes. This is **encapsulation**: if the module internally switches from EC2 to an auto-scaling group, the root outputs still work without change.

### Module Files

#### `modules/webserver/main.tf`

The module contains no `terraform {}` block and no `provider` block. It has its own `data "aws_ami"` source — the module is self-contained for AMI resolution, meaning the caller does not need to know Canonical's owner ID.

**`user_data` with Terraform variable interpolation:**
```hcl
user_data = <<-EOF
  #!/bin/bash
  apt-get update -y && apt-get install -y nginx
  echo "<h1>${var.project_name} — Served from Module</h1>" > /var/www/html/index.html
  systemctl enable nginx && systemctl start nginx
EOF
```

`${var.project_name}` is a **Terraform** interpolation — evaluated at plan time before the script reaches the EC2 instance. When `project_name = "bmi-health-tracker"`, the HTML written to disk is literally `<h1>bmi-health-tracker — Served from Module</h1>`. Compare to Lesson 02's `$(hostname)`, which is a bash substitution evaluated at runtime on the instance.

#### `modules/webserver/variables.tf`

Six input variables. Four have no default (required):

| Variable | Default | Required? | Purpose |
|---|---|---|---|
| `project_name` | *(none)* | **Yes** | Used in resource names and `user_data` |
| `environment` | *(none)* | **Yes** | Used in resource names |
| `vpc_id` | *(none)* | **Yes** | Security group must be in a specific VPC |
| `allowed_ssh_cidr` | *(none)* | **Yes** | SSH source IP restriction |
| `instance_type` | `"t2.micro"` | No | EC2 instance class |
| `key_name` | `"sarowar-ostad-mumbai"` | No | SSH key pair |

Required module inputs (no default) cause `terraform plan` to fail immediately with a clear error if the caller does not provide them — this is the module enforcing its contract with callers.

#### `modules/webserver/outputs.tf`

```hcl
output "instance_id" { value = aws_instance.web.id }
output "public_ip"   { value = aws_instance.web.public_ip }
output "ssh_command" { value = "ssh -i sarowar-ostad-mumbai.pem ubuntu@${aws_instance.web.public_ip}" }
output "app_url"     { value = "http://${aws_instance.web.public_ip}" }
```

Module outputs are the **only** values the module exposes to its caller. The root module cannot access `aws_security_group.web.id` or `data.aws_ami.ubuntu.id` from outside the module — those are private to the module.

---

## 5. Prerequisites

### Tools

```bash
terraform version        # >= 1.5.0
aws sts get-caller-identity   # confirms AWS credentials work
```

For full install instructions see [Lesson 01 Prerequisites](../01-terraform-fundamentals/README.md#5-prerequisites).

### EC2 Key Pair

The key pair `sarowar-ostad-mumbai` must exist in `ap-south-1`:
```bash
aws ec2 describe-key-pairs --key-names sarowar-ostad-mumbai --region ap-south-1
```

Set permissions on the `.pem` file:
```bash
chmod 400 ~/sarowar-ostad-mumbai.pem
```

### Your Public IP
```bash
curl ifconfig.me
# Use this as: allowed_ssh_cidr = "X.X.X.X/32"
```

### IAM Permissions

Same as Lesson 02 — your user needs EC2 permissions for DescribeImages, DescribeVpcs, CreateSecurityGroup, RunInstances, CreateTags, TerminateInstances, and related Describe actions. `AdministratorAccess` or `PowerUserAccess` covers all of these.

---

## 6. Step-by-Step Deployment

### Step 1: Navigate to This Folder

```bash
cd 04-modules
```

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — set your actual IP:
```hcl
aws_region       = "ap-south-1"
project_name     = "bmi-health-tracker"
environment      = "dev"
instance_type    = "t2.micro"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "203.0.113.45/32"   # your IP from: curl ifconfig.me
```

### Step 3: Initialize

```bash
terraform init
```

`terraform init` for a configuration that uses local modules:
1. Downloads the AWS provider plugin
2. Creates `.terraform/modules/` — a directory containing a symlink or copy of the local module
3. Creates `.terraform.lock.hcl`

Expected output includes:
```
Initializing modules...
- web_server in modules/webserver

Terraform has been successfully initialized!
```

The `Initializing modules...` line is new — it does not appear when there are no modules.

### Step 4: Plan

```bash
terraform plan
```

Expected output:
```
Terraform will perform the following actions:

  # module.web_server.aws_instance.web will be created
  + resource "aws_instance" "web" {
      ...
    }

  # module.web_server.aws_security_group.web will be created
  + resource "aws_security_group" "web" {
      ...
    }

Plan: 2 to add, 0 to change, 0 to destroy.
```

**Critical observation:** Resource addresses are prefixed with `module.web_server.` — for example `module.web_server.aws_instance.web` rather than just `aws_instance.web`. This is how Terraform namespaces resources inside modules. The same resource type can exist in multiple modules simultaneously without name conflicts.

### Step 5: Apply

```bash
terraform apply
```

Type `yes`. Takes approximately 30–45 seconds.

Expected outputs:
```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

app_url     = "http://13.x.x.x"
instance_id = "i-0xxxxxxxxxxxxxxxx"
public_ip   = "13.x.x.x"
ssh_command = "ssh -i sarowar-ostad-mumbai.pem ubuntu@13.x.x.x"
```

Outputs appear at the root level even though they are defined in the module — they flow up through the output chain.

---

## 7. Verifying the Deployment

### Test HTTP

```bash
# Wait 1-3 minutes for user_data (nginx install) to complete
curl http://$(terraform output -raw public_ip)
# Expected: <h1>bmi-health-tracker — Served from Module</h1>
```

The page now shows `${var.project_name}` resolved — proof that Terraform expanded the variable before writing the script.

### Connect via SSH

```bash
eval "$(terraform output -raw ssh_command | xargs)"
# or explicitly:
ssh -i ~/sarowar-ostad-mumbai.pem ubuntu@$(terraform output -raw public_ip)
```

### Inspect Module Resources in State

```bash
# List all resources — note the module prefix
terraform state list
# module.web_server.aws_instance.web
# module.web_server.aws_security_group.web

# Show details of the EC2 (note the full address including module prefix)
terraform state show module.web_server.aws_instance.web

# Show details of the security group
terraform state show module.web_server.aws_security_group.web
```

### Verify AWS Resource Names Match Module Variables

```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Name,Values=bmi-health-tracker-dev-webserver" \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}" \
  --output table
```

---

## 8. Understanding the Code

### The `module` Block — Every Part Explained

```hcl
module "web_server" {          # "web_server" is the local name of this module instance
  source = "./modules/webserver"  # path to the module directory (relative to THIS file)

  # Everything below is a module input variable assignment
  project_name     = var.project_name      # passes root var to module var
  environment      = var.environment
  vpc_id           = data.aws_vpc.default.id   # computed value, not a variable
  instance_type    = var.instance_type
  key_name         = var.key_name
  allowed_ssh_cidr = var.allowed_ssh_cidr
}
```

- `source` is required. For local modules it is a relative path starting with `./` or `../`. For registry modules it is `"hashicorp/consul/aws"`.
- The local name (`web_server`) determines how outputs are accessed: `module.web_server.<output_name>`.
- Input assignments must match variable names declared in `modules/webserver/variables.tf` exactly.
- You cannot pass a variable that the module does not declare — this causes a plan error.
- You must provide all required variables (those without defaults) — omitting one causes a plan error.

### How Terraform Initializes Local Modules

When you run `terraform init`:

```
.terraform/
  modules/
    modules.json          <- registry of module source paths
    web_server/           <- symlink or copy of modules/webserver/
```

Terraform creates a link between the module name (`web_server`) and its source path. If you change `source`, you must re-run `terraform init`. If you add a new `module` block, you must re-run `terraform init`.

### Resource Address Namespacing

In flat configurations (Lessons 01–03), resource addresses are: `aws_instance.web`

Inside a module, they are: `module.web_server.aws_instance.web`

The pattern is: `module.<module_name>.<resource_type>.<resource_name>`

For nested modules (module inside module): `module.outer.module.inner.aws_instance.web`

This namespace is used in:
- `terraform state list` output
- `terraform state show <address>`
- `terraform destroy -target=<address>`
- `terraform import <address> <aws_id>`
- Watching plan changes

### Why the Module Has No `provider` Block

Modules must not configure providers. This rule exists because:
1. The same module might be called from configurations targeting different accounts or regions
2. The provider version constraint is set once at the root level — not per-module
3. Modules with hardcoded providers cannot be reused across accounts

The module inherits the root's `provider "aws" { region = var.aws_region }` automatically. If a module needs to target a different region (e.g., creating a replication bucket in `us-east-1`), the root passes a [provider alias](https://developer.hashicorp.com/terraform/language/modules/develop/providers) to the module.

### Terraform Variable Interpolation vs Bash Substitution in `user_data`

```hcl
# In modules/webserver/main.tf:
user_data = <<-EOF
  echo "<h1>${var.project_name} — Served from Module</h1>" > /var/www/html/index.html
EOF
```

`${var.project_name}` is evaluated by Terraform at **plan time**, before the script is sent to AWS. When `project_name = "bmi-health-tracker"`, the string AWS receives is:

```bash
echo "<h1>bmi-health-tracker — Served from Module</h1>" > /var/www/html/index.html
```

Compare to Lesson 02's `$(hostname)` — evaluated by bash at **runtime** on the instance.

Rule of thumb:
- `${...}` with a `var.` or resource reference = Terraform interpolation, evaluated at plan time
- `$(...)` = bash command substitution, evaluated on the instance at boot

If you need a literal dollar sign in a heredoc (to use a bash variable like `$HOME`), use `$$`:
```hcl
user_data = <<-EOF
  echo "Home is: $$HOME"   # $$ becomes $ in the script
EOF
```

### Module Encapsulation — What the Caller Cannot See

From the root module, you can access:
- `module.web_server.instance_id` (declared output)
- `module.web_server.public_ip` (declared output)
- `module.web_server.ssh_command` (declared output)
- `module.web_server.app_url` (declared output)

You **cannot** access:
- `module.web_server.aws_instance.web.ami` (internal resource attribute)
- `module.web_server.aws_security_group.web.id` (internal resource attribute)
- `module.web_server.data.aws_ami.ubuntu.id` (internal data source)

If you need the SG ID or AMI ID at the root level, the module must declare them as outputs.

---

## 9. Making Changes Safely

### Change a Module Input (Project Name)

Edit `terraform.tfvars`:
```hcl
project_name = "my-app"
```

```bash
terraform plan
```

The plan shows:
- `-/+ module.web_server.aws_instance.web` (forces replacement — `user_data` contains `${var.project_name}`, which changes the script hash)
- `-/+ module.web_server.aws_security_group.web` (forces replacement — Name tag changes)

Changing `project_name` replaces both resources because it affects both the Name tag on the SG and the `user_data` script on the EC2.

### Change Instance Type

```bash
instance_type = "t3.micro"   # in terraform.tfvars
```

```bash
terraform plan   # -/+ module.web_server.aws_instance.web (forces replacement)
terraform apply
```

### Update Your SSH IP

```bash
allowed_ssh_cidr = "NEW_IP/32"   # in terraform.tfvars

terraform plan   # ~ module.web_server.aws_security_group.web (in-place SG rule update)
terraform apply
```

### Call the Module a Second Time (Extending the Lesson)

You can call the same module twice with different inputs — this is the primary advantage of modules:

```hcl
# In main.tf — add a second module call:
module "web_server_prod" {
  source = "./modules/webserver"

  project_name     = var.project_name
  environment      = "prod"           # different environment
  vpc_id           = data.aws_vpc.default.id
  instance_type    = "t3.small"        # different size
  key_name         = var.key_name
  allowed_ssh_cidr = var.allowed_ssh_cidr
}
```

Run `terraform init` again (new module block requires re-initialization), then `terraform apply`. This creates a second independent set of resources (SG + EC2) with `prod` in their names — without duplicating any code.

### Add a New Output to the Module

If you need the SG ID available at the root:

1. Add to `modules/webserver/outputs.tf`:
```hcl
output "security_group_id" { value = aws_security_group.web.id }
```

2. Add to root `outputs.tf`:
```hcl
output "security_group_id" { value = module.web_server.security_group_id }
```

3. Run `terraform plan` — no resource changes, only output additions.
4. Run `terraform apply`.

No `terraform init` needed for output-only changes.

---

## 10. Cleanup

```bash
terraform destroy
```

Resources are destroyed in reverse dependency order (EC2 first, then SG). Both are prefixed with `module.web_server.` in the destroy plan.

Expected:
```
Plan: 0 to add, 0 to change, 2 to destroy.

  # module.web_server.aws_instance.web will be destroyed
  # module.web_server.aws_security_group.web will be destroyed

Destroy complete! Resources: 2 destroyed.
```

Verify:
```bash
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Name,Values=bmi-health-tracker-dev-webserver" \
             "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
# Expected: empty
```

---

## 11. Key Concepts and Design Decisions

### Why Modules?

| Scenario | Without Modules | With Modules |
|---|---|---|
| Deploy the same stack for dev + prod | Copy-paste and maintain two copies | Call the module twice with different inputs |
| Fix a bug in the SG rules | Edit in every environment separately | Fix once in the module, re-apply everywhere |
| Onboard a new engineer | Explain 100+ lines of HCL | "It uses the `webserver` module — see `modules/webserver/`" |
| Enforce standards | No enforcement — engineers write freeform HCL | Module enforces naming, tagging, security rules |
| Upgrade the AMI | Update in every config separately | Update `data "aws_ami"` once in the module |

### Why `source = "./modules/webserver"` Not `../modules/webserver`?

Local module paths are relative to the file containing the `module` block. Because `main.tf` is in `04-modules/`, and the module is in `04-modules/modules/webserver/`, the correct path is `./modules/webserver`. This keeps the lesson folder self-contained — no dependency on files outside `04-modules/`.

### Why Does the Module Declare Its Own `data "aws_ami"`?

The module is self-contained. If the caller had to look up and pass the AMI ID, every caller would need to repeat the Canonical owner ID filter logic. Moving the AMI lookup inside the module means:
1. The correct AMI is always used regardless of how the module is called
2. The caller does not need to know Canonical's AWS account ID
3. AMI updates only need to be made in one place

This is the same reasoning behind putting shared logic inside a library function rather than requiring every caller to implement it.

### Module vs Flat Config — When to Use Each

| Situation | Recommendation |
|---|---|
| Learning Terraform basics | Flat config (Lessons 01–03) |
| Deploying the same pattern in 2+ places | Module |
| Infrastructure owned by one team, used by another | Module (published to registry or shared repo) |
| One-time resource (S3 bucket for Terraform state) | Flat config (bootstrap pattern from Lesson 03) |
| Standard building blocks (VPC, SG, EC2, RDS, ALB) | Module (Lessons 05–13) |

### Module Output Chaining

Root outputs in this lesson:
```hcl
output "public_ip" { value = module.web_server.public_ip }
```

Module output:
```hcl
output "public_ip" { value = aws_instance.web.public_ip }
```

The chain is: `aws_instance.web.public_ip` → module output → root output → `terraform output public_ip`.

This chaining pattern is used in every subsequent lesson. The root configuration only knows about inputs and outputs — never about internal resource attributes.

---

## 12. Common Errors and Fixes

### `Error: Module not installed`

```
Error: Module not installed

  on main.tf line 26, in module "web_server":
  26:   source = "./modules/webserver"

This module is not yet installed. Run "terraform init" to install all modules
required by this configuration.
```

**Cause:** You edited `main.tf` to add or change a module block but have not re-run `terraform init`.

**Fix:**
```bash
terraform init
```

Any change to a `module` block's `source` attribute requires re-initialization.

### `Error: Unsupported argument` in Module Call

```
Error: Unsupported argument

  on main.tf line 31, in module "web_server":
  31:   nonexistent_var = "value"

An argument named "nonexistent_var" is not expected here.
```

**Cause:** You passed an argument to the module that is not declared as a variable in `modules/webserver/variables.tf`.

**Fix:** Add the variable to `modules/webserver/variables.tf`, or remove the argument from the `module` block.

### `Error: Missing required argument` in Module Call

```
Error: Missing required argument

  on main.tf line 26, in module "web_server":
  26: module "web_server" {

The argument "vpc_id" is required, but no definition was found.
```

**Cause:** A required module input (no default) was not provided in the `module` block.

**Fix:** Add `vpc_id = data.aws_vpc.default.id` (or appropriate value) to the `module "web_server"` block.

### `Error: Unsupported attribute` When Accessing Module Output

```
Error: Unsupported attribute

  on outputs.tf line 2, in output "security_group_id":
  value = module.web_server.security_group_id

This object does not have an attribute named "security_group_id".
```

**Cause:** Attempting to access a module output that has not been declared in `modules/webserver/outputs.tf`.

**Fix:** Add the output to `modules/webserver/outputs.tf`:
```hcl
output "security_group_id" { value = aws_security_group.web.id }
```

### `terraform state list` Shows No Resources After Apply

```bash
terraform state list
# (empty output)
```

**Cause:** You are in the wrong directory — possibly in `modules/webserver/` instead of `04-modules/`. Modules do not have their own state; they are managed by the root configuration.

**Fix:**
```bash
cd 04-modules   # ensure you are in the root lesson directory
terraform state list
# module.web_server.aws_instance.web
# module.web_server.aws_security_group.web
```

### SSH: `Permission denied (publickey)`

**Cause A:** Wrong username — Ubuntu 22.04 on EC2 uses `ubuntu`, not `ec2-user`.

**Cause B:** Wrong key file path.

**Fix:** Use the exact ssh_command from outputs:
```bash
terraform output -raw ssh_command
# Copy and paste the exact command shown
```

---

## 13. What Comes Next

| Lesson | How It Uses Module Concepts from This Lesson |
|---|---|
| **05 — Networking VPC** | The `vpc` module is introduced: takes CIDR inputs, outputs subnet IDs |
| **06 — EC2 Deployment** | The `ec2` module runs user_data scripts for the full app stack |
| **07 — RDS Database** | The `rds` and `secrets` modules are introduced |
| **08–09 — 3-Tier** | All infra composed from 5–7 module calls — the root has zero direct resources |
| **13 — Complete Production** | Seven modules called from one root — entire production environment as code |

---

## Dependency Map

```
terraform.tfvars
      |
      v
Root variables.tf
      |
      +-- var.project_name, var.environment, var.instance_type,
      |   var.key_name, var.allowed_ssh_cidr
      v
Root main.tf
      |
      +-- data.aws_vpc.default  (read-only: resolves default VPC ID)
      |
      +-- module "web_server" {
      |     source           = "./modules/webserver"
      |     project_name     = var.project_name
      |     environment      = var.environment
      |     vpc_id           = data.aws_vpc.default.id   <-- flows in
      |     instance_type    = var.instance_type
      |     key_name         = var.key_name
      |     allowed_ssh_cidr = var.allowed_ssh_cidr
      |   }
      |
      v
Module: modules/webserver/
      |
      +-- data.aws_ami.ubuntu          (AMI lookup — no external dependency)
      |
      +-- aws_security_group.web       (depends on: var.vpc_id, var.allowed_ssh_cidr,
      |                                              var.project_name, var.environment)
      |
      +-- aws_instance.web             (depends on: data.aws_ami.ubuntu.id,
      |                                              aws_security_group.web.id,
      |                                              var.instance_type, var.key_name,
      |                                              var.project_name (in user_data))
      |
      Module outputs (flow back up to root):
        instance_id, public_ip, ssh_command, app_url
      |
      v
Root outputs.tf
      module.web_server.instance_id
      module.web_server.public_ip
      module.web_server.ssh_command
      module.web_server.app_url
```

Three new dependency patterns introduced in this lesson:
1. **Root-to-module:** Root passes values into a module via input variables
2. **Module output back to root:** Module exposes values the root can read and re-expose
3. **Module internal dependency:** `aws_instance.web` inside the module depends on `aws_security_group.web` inside the same module — Terraform resolves this within the module boundary

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
