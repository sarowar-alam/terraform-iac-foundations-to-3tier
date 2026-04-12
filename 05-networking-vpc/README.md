# 05  -  Networking VPC

> **Course Position:** Lesson 05 of 13  -  Module 8, Section 5: Custom VPC and Network Isolation
> **Objective:** Replace the default VPC used in previous lessons with a production-grade custom VPC: six subnets across two Availability Zones, three isolated routing tiers, an Internet Gateway, and a NAT Gateway  -  all built from a reusable module.

From this lesson forward, every EC2 instance and RDS database lives in **this VPC**. The network layout established here is the foundation for the 3-tier applications built in Lessons 07 - 13. Understanding the CIDR plan and routing tiers is essential before proceeding.

**Prerequisites:** Complete Lessons 01 - 04. The `module` block pattern (Lesson 04) is used here. Understanding of `count`, `list` variables, and module input/output chaining is assumed.

---

## Table of Contents

1. [What This Lesson Does](#1-what-this-lesson-does)
2. [Technology Stack](#2-technology-stack)
3. [Network Architecture](#3-network-architecture)
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

This lesson creates a complete, production-grade VPC networking stack using a single module call. The VPC provides three levels of network isolation:

| Tier | Subnets | CIDR | What Lives Here | Internet Access |
|---|---|---|---|---|
| Public | 2 (one per AZ) | 10.0.1.0/24, 10.0.2.0/24 | ALB, Bastion host, NAT Gateway | Direct via Internet Gateway |
| Private App | 2 (one per AZ) | 10.0.3.0/24, 10.0.4.0/24 | Backend EC2, Frontend EC2 | Outbound only via NAT Gateway |
| Private DB | 2 (one per AZ) | 10.0.5.0/24, 10.0.6.0/24 | RDS PostgreSQL | **None  -  no route to internet** |

| New Concept | Where You See It |
|---|---|
| `count` meta-argument | `modules/vpc/main.tf`  -  creates 2 subnets of each type with one block |
| `list(string)` variable type | `variables.tf`  -  `availability_zones`, `*_subnet_cidrs` |
| `count.index` referencing | `modules/vpc/main.tf`  -  `var.availability_zones[count.index]` |
| `[*]` splat operator in output | `modules/vpc/outputs.tf`  -  `aws_subnet.public[*].id` |
| `depends_on` explicit ordering | `modules/vpc/main.tf`  -  EIP and NAT GW wait for IGW |
| Internet Gateway + route | `modules/vpc/main.tf`  -  public route table |
| NAT Gateway + Elastic IP | `modules/vpc/main.tf`  -  outbound-only internet for private subnets |
| Isolated route table | `modules/vpc/main.tf`  -  private_db has no `0.0.0.0/0` route |
| `enable_dns_hostnames` | `modules/vpc/main.tf`  -  required for RDS and SSM in later lessons |

**This lesson creates no EC2 instances or databases**  -  pure networking infrastructure only. The result is 19 AWS resources and a set of subnet IDs that all subsequent lessons consume.

---

## 2. Technology Stack

### Tools Required

| Tool | Minimum Version | Purpose | Install |
|---|---|---|---|
| Terraform | 1.5.0 | Infrastructure provisioning | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | Verify network resources post-deploy | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

### AWS Services Created

| Resource | Count | Name Pattern | Purpose |
|---|---|---|---|
| VPC | 1 | `bmi-health-tracker-dev-vpc` | Isolated network boundary |
| Subnet (public) | 2 | `...-public-ap-south-1a/1b` | ALB, bastion, NAT GW |
| Subnet (private-app) | 2 | `...-private-app-ap-south-1a/1b` | Application EC2 instances |
| Subnet (private-db) | 2 | `...-private-db-ap-south-1a/1b` | RDS databases |
| Internet Gateway | 1 | `...-igw` | Public subnet internet access |
| Elastic IP | 1 | `...-nat-eip` | Fixed IP for NAT Gateway |
| NAT Gateway | 1 | `...-nat-gw` | Private subnet outbound access |
| Route Table (public) | 1 | `...-rt-public` | Routes `0.0.0.0/0` â†’ IGW |
| Route Table (private-app) | 1 | `...-rt-private-app` | Routes `0.0.0.0/0` â†’ NAT GW |
| Route Table (private-db) | 1 | `...-rt-private-db` | Local VPC routes only (no internet) |
| Route Table Association | 6 | (no Name tag) | Binds each subnet to its route table |
| **Total** | **19** | | |

### Provider Configuration

```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

`default_tags` applies `Project`, `Environment`, and `ManagedBy` to all 19 resources automatically.

---

## 3. Network Architecture

### VPC CIDR Layout

```
VPC: 10.0.0.0/16  (65,536 addresses  -  ap-south-1, Mumbai)
|
+-- PUBLIC TIER (internet-reachable)
|   +-- 10.0.1.0/24  public-ap-south-1a   (256 addr) <- ALB, Bastion, NAT GW
|   +-- 10.0.2.0/24  public-ap-south-1b   (256 addr) <- ALB (HA requirement)
|
+-- PRIVATE APP TIER (outbound internet via NAT only)
|   +-- 10.0.3.0/24  private-app-ap-south-1a  (256 addr) <- Backend EC2
|   +-- 10.0.4.0/24  private-app-ap-south-1b  (256 addr) <- Frontend EC2
|
+-- PRIVATE DB TIER (no internet  -  VPC-local only)
    +-- 10.0.5.0/24  private-db-ap-south-1a   (256 addr) <- RDS primary
    +-- 10.0.6.0/24  private-db-ap-south-1b   (256 addr) <- RDS standby (Multi-AZ)
```

### Routing  -  How Traffic Flows

```
INTERNET
    |
    v
Internet Gateway (bmi-health-tracker-dev-igw)
    |
    +----> Public Route Table  (10.0.1.0/24, 10.0.2.0/24)
    |        Route: 0.0.0.0/0 -> IGW
    |        Route: 10.0.0.0/16 -> local (VPC-internal)
    |
    |         Public Subnets:  ALB, Bastion EC2, NAT Gateway
    |              |
    |              |  NAT Gateway (Elastic IP: fixed public IP)
    |              v
    +----> Private App Route Table  (10.0.3.0/24, 10.0.4.0/24)
    |        Route: 0.0.0.0/0 -> NAT Gateway  (outbound only)
    |        Route: 10.0.0.0/16 -> local
    |
    |         Private App Subnets:  EC2 instances
    |         (can reach internet outbound for apt-get, npm, git)
    |         (cannot be reached from internet  -  no inbound route)
    |
    +----> Private DB Route Table  (10.0.5.0/24, 10.0.6.0/24)
             Route: 10.0.0.0/16 -> local  (VPC-internal ONLY)
             NO 0.0.0.0/0 route  -  DB tier cannot send or receive internet traffic

             Private DB Subnets: RDS PostgreSQL
             (ONLY reachable from within the VPC  -  no exceptions)
```

### Two-AZ Layout for High Availability

```
ap-south-1a                         ap-south-1b
-----------                         -----------
10.0.1.0/24  public-1a              10.0.2.0/24  public-1b
10.0.3.0/24  private-app-1a         10.0.4.0/24  private-app-1b
10.0.5.0/24  private-db-1a          10.0.6.0/24  private-db-1b
    |
    v
NAT Gateway (in public-1a only)
Elastic IP: <fixed public IP>

NOTE: Single NAT GW is a cost-efficiency choice.
For production HA: one NAT GW per AZ (see Key Design Decisions).
```

### Resource Dependency Chain

```
aws_vpc.main
      |
      +-> aws_subnet.public[0,1]       (need vpc_id)
      +-> aws_subnet.private_app[0,1]  (need vpc_id)
      +-> aws_subnet.private_db[0,1]   (need vpc_id)
      |
      +-> aws_internet_gateway.main    (attached to VPC)
              |
              | (depends_on ensures IGW is attached before EIP/NAT created)
              v
      aws_eip.nat
              |
              v
      aws_nat_gateway.main             (needs EIP allocation_id + public subnet_id)
              |
      aws_route_table.public           (route: 0.0.0.0/0 -> IGW)
      aws_route_table.private_app      (route: 0.0.0.0/0 -> NAT GW)
      aws_route_table.private_db       (no internet route)
              |
      aws_route_table_association.*    (binds subnet to route table)
```

---

## 4. Folder Structure and File Reference

```
05-networking-vpc/
|-- main.tf                         Root: provider, default_tags, module "vpc" call
|-- variables.tf                    8 variables: region, project, env, vpc_cidr, 4 CIDR lists
|-- outputs.tf                      8 outputs: vpc_id, vpc_cidr, 3 subnet ID lists, IGW, NAT
|-- terraform.tfvars.example        Pre-filled with all default values
|-- README.md                       This file
|
+-- modules/
    +-- vpc/
        |-- main.tf                 Module: all 19 resources created here
        |-- variables.tf            Module inputs: 7 variables (2 required)
        +-- outputs.tf              Module outputs: 8 values exposed to root

|-- (auto-generated)
|-- .terraform/                     Provider binaries + module link
|-- .terraform.lock.hcl             Provider version lock
+-- terraform.tfstate               Local state (19 resources)
```

### Root Files

#### `main.tf` (root)

```hcl
module "vpc" {
  source = "./modules/vpc"

  project_name             = var.project_name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = var.availability_zones
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
}
```

The root has **zero resource or data blocks**  -  everything is delegated to the VPC module. The root's job is: configure the provider, define variables, call the module, expose outputs.

#### `variables.tf` (root)

Eight variables  -  all have defaults. No required inputs at the root level. The CIDR variables use `list(string)` type:

```hcl
variable "availability_zones" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}
```

`list(string)` allows passing ordered collections of values. The ordering matters  -  `public_subnet_cidrs[0]` is deployed in `availability_zones[0]` (both are `ap-south-1a`).

#### `outputs.tf` (root)

Eight outputs, all passed through from `module.vpc.*`:

```hcl
output "public_subnet_ids"      { value = module.vpc.public_subnet_ids }
output "private_app_subnet_ids" { value = module.vpc.private_app_subnet_ids }
output "private_db_subnet_ids"  { value = module.vpc.private_db_subnet_ids }
output "nat_gateway_public_ip"  { value = module.vpc.nat_gateway_public_ip }
```

The subnet ID lists are what later lessons consume  -  EC2 instances are placed in specific subnets, and RDS instances require a DB subnet group built from the private DB subnet IDs.

### Module Files

#### `modules/vpc/main.tf`

Eleven distinct resource types, all using variables with no hardcoded values.

**VPC with DNS enabled:**
```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}
```
Both DNS flags are always `true`. `enable_dns_support` enables DNS resolution within the VPC. `enable_dns_hostnames` gives EC2 instances their `ec2.internal` DNS names. Both are required for RDS endpoint resolution and AWS Systems Manager (SSM) Session Manager in later lessons.

**Subnet creation with `count`:**
```hcl
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)   # evaluates to 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]   # [0] = "10.0.1.0/24"
  availability_zone = var.availability_zones[count.index]    # [0] = "ap-south-1a"
  map_public_ip_on_launch = true   # public subnets only
}
```

`count = 2` creates two resources: `aws_subnet.public[0]` and `aws_subnet.public[1]`. `count.index` is `0` for the first and `1` for the second. This avoids writing two near-identical `aws_subnet` blocks.

**Public subnets set `map_public_ip_on_launch = true`**  -  EC2 instances launched here automatically get a public IP. Private subnets do not set this (defaulting to `false`)  -  instances there must use private IPs only.

**EIP and NAT GW with `depends_on`:**
```hcl
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
}
```
`depends_on` forces Terraform to attach the Internet Gateway to the VPC before provisioning the Elastic IP or NAT Gateway. Without this, there is a race condition where the NAT GW creation might begin before the IGW is fully attached, causing an `InvalidVpcID.NotFound` or similar error.

**Private DB route table  -  intentionally no internet route:**
```hcl
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  # No route block  -  only the implicit local VPC route exists
}
```
This is a deliberate security boundary. RDS databases in the private-db subnets:
- Can be reached from backend EC2 instances (same VPC, local route)
- Cannot initiate outbound connections to the internet
- Cannot be reached from the internet
- Cannot download packages or call external APIs

#### `modules/vpc/variables.tf`

Seven variables. `project_name` and `environment` are **required** (no defaults)  -  the module enforces these must be provided:

| Variable | Type | Default | Required? |
|---|---|---|---|
| `project_name` | `string` | *(none)* | **Yes** |
| `environment` | `string` | *(none)* | **Yes** |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | No |
| `availability_zones` | `list(string)` | `["ap-south-1a", "ap-south-1b"]` | No |
| `public_subnet_cidrs` | `list(string)` | `["10.0.1.0/24", "10.0.2.0/24"]` | No |
| `private_app_subnet_cidrs` | `list(string)` | `["10.0.3.0/24", "10.0.4.0/24"]` | No |
| `private_db_subnet_cidrs` | `list(string)* | `["10.0.5.0/24", "10.0.6.0/24"]` | No |

#### `modules/vpc/outputs.tf`

Eight outputs. Three are lists of IDs using the **splat expression** `[*]`:

```hcl
output "public_subnet_ids" {
  value = aws_subnet.public[*].id   # returns ["subnet-aaa", "subnet-bbb"]
}
```

`[*]` is the splat operator  -  it expands a list of resources and extracts the same attribute from each. The result is a list in the same order as `count.index`. This output is consumed by later lessons as: `module.vpc.public_subnet_ids[0]` for the first AZ's subnet ID.

---

## 5. Prerequisites

### Tools

```bash
terraform version           # >= 1.5.0
aws sts get-caller-identity # must return your account ID
```

### IAM Permissions Required

This lesson creates more AWS resources than any previous lesson. Your user needs:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:DescribeVpcs", "ec2:ModifyVpcAttribute",
    "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:DescribeSubnets", "ec2:ModifySubnetAttribute",
    "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
    "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
    "ec2:DescribeInternetGateways",
    "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DescribeAddresses",
    "ec2:CreateNatGateway", "ec2:DeleteNatGateway", "ec2:DescribeNatGateways",
    "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
    "ec2:CreateRoute", "ec2:DeleteRoute",
    "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
    "ec2:DescribeRouteTables",
    "ec2:CreateTags", "ec2:DeleteTags"
  ],
  "Resource": "*"
}
```

`AdministratorAccess` or `PowerUserAccess` covers all of the above.

### Cost Awareness

The **NAT Gateway** is the most expensive resource in this lesson:
- $0.045/hour baseline (running cost)  -  approximately $1.08/day
- Plus $0.045/GB of data processed

The Elastic IP also incurs a small charge when not attached to a running NAT GW (~$0.005/hour).

**Destroy after the lesson to avoid ongoing charges.** See [Section 10  -  Cleanup](#10-cleanup).

---

## 6. Step-by-Step Deployment

### Step 1: Navigate to This Folder

```bash
cd 05-networking-vpc
```

### Step 2: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

The defaults work as-is  -  no required values need changing. Open `terraform.tfvars` to review:

```hcl
aws_region   = "ap-south-1"
project_name = "bmi-health-tracker"
environment  = "dev"
vpc_cidr     = "10.0.0.0/16"

availability_zones       = ["ap-south-1a", "ap-south-1b"]
public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
private_app_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
private_db_subnet_cidrs  = ["10.0.5.0/24", "10.0.6.0/24"]
```

The CIDR plan is designed so adjacent tiers are adjacent in the address space:
- `10.0.1-2.0/24` = public
- `10.0.3-4.0/24` = private-app
- `10.0.5-6.0/24` = private-db

### Step 3: Initialize

```bash
terraform init
```

Expected output includes:
```
Initializing modules...
- vpc in modules/vpc

Terraform has been successfully initialized!
```

### Step 4: Plan

```bash
terraform plan
```

Expected summary:
```
Plan: 19 to add, 0 to change, 0 to destroy.
```

Verify the plan shows:
- `module.vpc.aws_vpc.main`  -  1 VPC, CIDR `10.0.0.0/16`
- `module.vpc.aws_subnet.public[0]` and `[1]`  -  `map_public_ip_on_launch = true`
- `module.vpc.aws_subnet.private_app[0]` and `[1]`  -  no `map_public_ip_on_launch`
- `module.vpc.aws_subnet.private_db[0]` and `[1]`  -  no `map_public_ip_on_launch`
- `module.vpc.aws_nat_gateway.main`  -  `subnet_id` is the first public subnet
- `module.vpc.aws_route_table.private_db`  -  **no route block** (confirm no `0.0.0.0/0`)

### Step 5: Apply

```bash
terraform apply
```

Type `yes`. The NAT Gateway takes the longest to provision (~1 - 2 minutes). Other resources create in seconds.

Expected final output:
```
Apply complete! Resources: 19 added, 0 changed, 0 destroyed.

Outputs:

internet_gateway_id    = "igw-0xxxxxxxxxxxxxxxx"
nat_gateway_id         = "nat-0xxxxxxxxxxxxxxxx"
nat_gateway_public_ip  = "13.x.x.x"
private_app_subnet_ids = tolist(["subnet-0xxxxxxxx", "subnet-0xxxxxxxx"])
private_db_subnet_ids  = tolist(["subnet-0xxxxxxxx", "subnet-0xxxxxxxx"])
public_subnet_ids      = tolist(["subnet-0xxxxxxxx", "subnet-0xxxxxxxx"])
vpc_cidr               = "10.0.0.0/16"
vpc_id                 = "vpc-0xxxxxxxxxxxxxxxx"
```

---

## 7. Verifying the Deployment

### Confirm the VPC

```bash
VPC_ID=$(terraform output -raw vpc_id)

aws ec2 describe-vpcs \
  --vpc-ids $VPC_ID \
  --region ap-south-1 \
  --query "Vpcs[0].{ID:VpcId,CIDR:CidrBlock,DNS:EnableDnsHostnames}" \
  --output table
# Expected: CIDR=10.0.0.0/16, DNS=True
```

### Confirm Subnets and Their Tiers

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region ap-south-1 \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}" \
  --output table
```

Expected output (6 rows):

```
Name                                          CIDR            AZ           PublicIP
bmi-health-tracker-dev-public-ap-south-1a     10.0.1.0/24     ap-south-1a  True
bmi-health-tracker-dev-public-ap-south-1b     10.0.2.0/24     ap-south-1b  True
bmi-health-tracker-dev-private-app-ap-south-1a 10.0.3.0/24   ap-south-1a  False
bmi-health-tracker-dev-private-app-ap-south-1b 10.0.4.0/24   ap-south-1b  False
bmi-health-tracker-dev-private-db-ap-south-1a  10.0.5.0/24   ap-south-1a  False
bmi-health-tracker-dev-private-db-ap-south-1b  10.0.6.0/24   ap-south-1b  False
```

`PublicIP = True` on public subnets only  -  confirmed.

### Confirm Internet Gateway

```bash
IGW_ID=$(terraform output -raw internet_gateway_id)

aws ec2 describe-internet-gateways \
  --internet-gateway-ids $IGW_ID \
  --region ap-south-1 \
  --query "InternetGateways[0].{ID:InternetGatewayId,VPC:Attachments[0].VpcId,State:Attachments[0].State}" \
  --output table
# Expected: State=available, VPC=<your vpc_id>
```

### Confirm NAT Gateway and Elastic IP

```bash
NAT_ID=$(terraform output -raw nat_gateway_id)
NAT_IP=$(terraform output -raw nat_gateway_public_ip)

aws ec2 describe-nat-gateways \
  --nat-gateway-ids $NAT_ID \
  --region ap-south-1 \
  --query "NatGateways[0].{ID:NatGatewayId,State:State,PublicIP:NatGatewayAddresses[0].PublicIp,SubnetID:SubnetId}" \
  --output table
# Expected: State=available, PublicIP=<nat_gateway_public_ip output>
```

### Confirm Route Tables

```bash
# List all route tables for this VPC
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region ap-south-1 \
  --query "RouteTables[].{Name:Tags[?Key=='Name']|[0].Value,Routes:Routes[].DestinationCidrBlock}" \
  --output table
```

Verify:
- `rt-public`  -  has both `10.0.0.0/16` (local) and `0.0.0.0/0` (IGW)
- `rt-private-app`  -  has both `10.0.0.0/16` (local) and `0.0.0.0/0` (NAT GW)
- `rt-private-db`  -  has **only** `10.0.0.0/16` (local)  -  no `0.0.0.0/0`

### Confirm Route Table Associations

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region ap-south-1 \
  --query "RouteTables[].{RT:Tags[?Key=='Name']|[0].Value,Subnets:Associations[].SubnetId}" \
  --output table
```

Each route table should show 2 associated subnet IDs.

### Inspect State

```bash
terraform state list
# Shows all 19 module.vpc.* resources

terraform state show module.vpc.aws_nat_gateway.main
# Shows full NAT GW config including subnet_id and allocation_id
```

---

## 8. Understanding the Code

### `count` Meta-Argument  -  Creating Multiple Resources from One Block

Without `count`, creating 2 public subnets requires two near-identical blocks:
```hcl
# Without count  -  repetitive
resource "aws_subnet" "public_1a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-south-1a"
}
resource "aws_subnet" "public_1b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-south-1b"
}
```

With `count`:
```hcl
# With count  -  DRY (Don't Repeat Yourself)
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)   # = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]   # [0]="10.0.1.0/24", [1]="10.0.2.0/24"
  availability_zone = var.availability_zones[count.index]    # [0]="ap-south-1a", [1]="ap-south-1b"
}
```

This creates `aws_subnet.public[0]` and `aws_subnet.public[1]`. To add a third AZ, add a CIDR to `public_subnet_cidrs`  -  no code change needed.

`count.index` starts at `0`. The lists `public_subnet_cidrs` and `availability_zones` must be the same length  -  `count.index` is used for both simultaneously.

### The Splat Operator `[*]` in Outputs

```hcl
output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
```

`aws_subnet.public` is a list of two subnet resources (because `count = 2`). `[*].id` extracts the `.id` attribute from each element, returning `["subnet-aaa", "subnet-bbb"]` as a list.

This is equivalent to: `[aws_subnet.public[0].id, aws_subnet.public[1].id]`

Later lessons use this output as:
```hcl
subnet_id = module.vpc.public_subnet_ids[0]   # first AZ's public subnet
```

### `depends_on`  -  Explicit Dependency for Non-Obvious Ordering

```hcl
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
}
```

Terraform normally infers dependencies from resource attribute references. The EIP references no IGW attributes  -  there is no `= aws_internet_gateway.main.id` anywhere in the EIP block. However, an EIP allocated to a VPC-based NAT Gateway requires the Internet Gateway to be **attached** to the VPC first (AWS infrastructure requirement). Without `depends_on`, Terraform might provision the EIP before the IGW is attached.

`depends_on` is used sparingly  -  only when the real dependency exists but Terraform cannot infer it from attribute references. Over-using `depends_on` slows down plans because it defeats Terraform's parallel execution.

### Why One NAT Gateway, Not Two

The module creates one NAT Gateway in `ap-south-1a` (`aws_subnet.public[0]`). Both private-app subnets (1a and 1b) route through this single NAT Gateway.

**Consequence:** If `ap-south-1a` experiences an outage, instances in `ap-south-1b` (private-app) lose outbound internet access (cannot reach apt servers, AWS APIs, etc.), even though `ap-south-1b` itself is healthy.

**For production HA**, create one NAT GW per AZ:
```hcl
# Production pattern (not used here for cost efficiency)
resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}
```

For this course (non-production), one NAT GW saves ~$0.045/hour (~$32/month).

### Why `enable_dns_hostnames = true`

RDS endpoints are DNS names like `bmi-db.xxx.ap-south-1.rds.amazonaws.com`. For EC2 instances to resolve these within the VPC, `enable_dns_support = true` is required. `enable_dns_hostnames = true` is additionally required for SSM Session Manager (Lessons 10+) and for some AWS service endpoints.

Both flags are set on every VPC in this course. Disabling either would break RDS connectivity or SSM without any obvious error message.

### CIDR Planning Principles Applied

The `/16` VPC gives 65,536 addresses. Each `/24` subnet gives 256 addresses (251 usable  -  AWS reserves 5 per subnet). The layout:

```
10.0.0.0/24   -  RESERVED (not used  -  avoids confusion with the network address)
10.0.1.0/24   -  public-1a
10.0.2.0/24   -  public-1b
10.0.3.0/24   -  private-app-1a
10.0.4.0/24   -  private-app-1b
10.0.5.0/24   -  private-db-1a
10.0.6.0/24   -  private-db-1b
10.0.7-255.0/24  -  AVAILABLE for future use within this VPC
```

Using `/24` for each subnet keeps CIDR math simple. For larger deployments, `/22` (1024 addresses) per subnet is common.

---

## 9. Making Changes Safely

### Change the Environment Tag

```bash
# In terraform.tfvars:
environment = "staging"

terraform plan
```

The plan shows `~ module.vpc.aws_vpc.main` and all 6 subnets with Name tag updates (in-place, no recreation). Route tables and associations are also updated. No recreation  -  tag changes are always in-place.

### Add a Third AZ

Edit `terraform.tfvars`:
```hcl
availability_zones       = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24", "10.0.10.0/24"]
private_app_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24", "10.0.11.0/24"]
private_db_subnet_cidrs  = ["10.0.5.0/24", "10.0.6.0/24", "10.0.12.0/24"]
```

```bash
terraform plan   # shows 3 new subnets + 3 new RT associations to add
terraform apply
```

The `count`-based subnet blocks handle the additional entry automatically. No code change required.

### Change the VPC CIDR

**WARNING:** Changing `vpc_cidr` forces replacement of the VPC and **all 19 resources** (everything depends on the VPC ID). All subnet CIDRs must fall within the new VPC CIDR.

```bash
# In terraform.tfvars:
vpc_cidr = "172.16.0.0/16"

terraform plan
# Will show: -/+ module.vpc.aws_vpc.main (must be replaced)
# And all 18 dependent resources as -/+
```

This is a destructive change. In production, VPC CIDR changes require a migration plan  -  you cannot resize a VPC in-place.

### Verify No Overlap with Existing VPCs

Before deploying to a new AWS account, check for CIDR conflicts:

```bash
aws ec2 describe-vpcs \
  --region ap-south-1 \
  --query "Vpcs[].{ID:VpcId,CIDR:CidrBlock,Default:IsDefault}" \
  --output table
```

The default VPC uses `172.31.0.0/16`. This module uses `10.0.0.0/16`  -  no overlap.

---

## 10. Cleanup

```bash
terraform destroy
```

Terraform destroys resources in reverse dependency order:
1. Route table associations (unlink subnets from route tables)
2. Route tables
3. NAT Gateway (takes ~1 minute to delete)
4. Elastic IP (released)
5. Internet Gateway (detached and deleted)
6. Subnets (6)
7. VPC

Expected:
```
Plan: 0 to add, 0 to change, 19 to destroy.
...
Destroy complete! Resources: 19 destroyed.
```

The NAT Gateway deletion takes the longest  -  Terraform waits for it to reach `deleted` state (~60 seconds).

Verify nothing remains:
```bash
aws ec2 describe-vpcs \
  --region ap-south-1 \
  --filters "Name=tag:ManagedBy,Values=terraform" \
  --query "Vpcs[].VpcId" \
  --output text
# Expected: empty
```

---

## 11. Key Concepts and Design Decisions

### Three-Tier Isolation  -  Why It Matters

| Attack Scenario | Without Network Isolation | With Three-Tier VPC |
|---|---|---|
| Internet scanner reaches RDS | Possible if SG misconfigured | Impossible  -  no route exists |
| Compromised EC2 exfiltrates DB | Possible | DB subnet blocked from internet |
| Leaked RDS password used externally | Direct connection possible | Must also compromise an EC2 first |
| DDoS on backend EC2 | EC2 directly exposed | Must go through ALB (from Lesson 09) |

Network isolation is defense-in-depth. Even if every security group were misconfigured to allow all traffic, the routing tables would still block DB internet access.

### Private DB Route Table  -  Zero Internet Routes

This is the most important security property of the VPC. The private DB route table is defined as:

```hcl
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  # NO route block
}
```

AWS automatically adds the local VPC route (`10.0.0.0/16 -> local`). No other route is added. This is not an oversight  -  it is a deliberate constraint. Even if someone adds `publicly_accessible = true` to an RDS resource (which is blocked in the RDS module), the database still cannot be reached from the internet because no route exists.

### `map_public_ip_on_launch`  -  Public Subnets Only

Setting `map_public_ip_on_launch = true` on public subnets means any EC2 launched there gets a public IP automatically. Private subnets do not have this  -  instances there get only private IPs.

This affects which instances are directly reachable from the internet and which must be reached via a bastion host or ALB. It is a subnet-level default, not a resource-level decision.

### Why Two AZs Minimum?

AWS ALB requires target instances in at least two AZs. RDS Multi-AZ requires a subnet group spanning at least two AZs. By building both AZs from the start, the VPC is ready for:
- ALB deployment (Lesson 09)
- RDS Multi-AZ failover (Lesson 13)

A single-AZ VPC would require rebuilding the network before adding an ALB.

### NAT Gateway vs NAT Instance

AWS offers two options for private-subnet internet access:

| | NAT Gateway (used here) | NAT Instance |
|---|---|---|
| Setup | One resource, AWS-managed | EC2 instance + custom routing |
| Availability | AWS SLA, auto-scales | Single point of failure unless clustered |
| Bandwidth | Up to 100 Gbps | Limited by instance type |
| Cost | $0.045/hr + $0.045/GB | EC2 cost (~$0.01/hr for t3.micro) |
| Management | None | OS patches, monitoring |

NAT Gateway is the production standard. NAT instances are an outdated cost-saving measure no longer recommended.

---

## 12. Common Errors and Fixes

### `Error: InvalidSubnet.Conflict`  -  CIDR Overlap

```
Error: InvalidSubnet.Conflict: The CIDR '10.0.1.0/24' conflicts with another subnet
```

**Cause:** A subnet with this CIDR already exists in the VPC (e.g., from a previous partial apply).

**Fix:** Check for orphaned subnets:
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc_id>" \
  --region ap-south-1 \
  --query "Subnets[].{CIDR:CidrBlock,ID:SubnetId}" \
  --output table
```

If found, either import them into state (`terraform import`) or delete manually and re-apply.

### `Error: NatGatewayLimitExceeded`

```
Error: NatGatewayLimitExceeded: The maximum number of NAT gateways has been reached
```

**Cause:** AWS default limit is 5 NAT Gateways per AZ per account. Likely hit if you applied and destroyed multiple times without the destroy completing.

**Fix:** Check for existing NAT GWs:
```bash
aws ec2 describe-nat-gateways \
  --region ap-south-1 \
  --query "NatGateways[?State!='deleted'].{ID:NatGatewayId,State:State}" \
  --output table
```

Delete any in `pending` or `available` state that are not Terraform-managed, or request a limit increase from AWS Support.

### `Error: AddressLimitExceeded`  -  Elastic IP

```
Error: AddressLimitExceeded: The maximum number of addresses has been reached.
```

**Cause:** AWS default limit is 5 Elastic IPs per region. May be reached if EIPs from previous applies were not released.

**Fix:** List and release unattached EIPs:
```bash
aws ec2 describe-addresses \
  --region ap-south-1 \
  --query "Addresses[?AssociationId==null].AllocationId" \
  --output text
# For each unattached EIP AllocationId:
aws ec2 release-address --allocation-id eipalloc-xxx --region ap-south-1
```

### `terraform destroy` Hangs on NAT Gateway

**Cause:** NAT Gateway deletion takes 60 - 90 seconds. Terraform waits for the state to reach `deleted`.

**Fix:** This is normal. Do not interrupt. If it times out:
```bash
# Check current state
aws ec2 describe-nat-gateways \
  --nat-gateway-ids <nat_id> \
  --query "NatGateways[0].State"

# Once deleted, re-run destroy
terraform destroy
```

### After `terraform apply`, Route Table Shows No Routes in Console

**Cause:** AWS Console may require a page refresh. The local VPC route (`10.0.0.0/16 -> local`) is implicit and always present regardless of what Terraform shows.

**Fix:** Refresh the Console, or verify with CLI:
```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region ap-south-1 \
  --query "RouteTables[].Routes"
```

### `Error: Error waiting for NAT Gateway ... timeout`

```
Error: Error waiting for NAT Gateway to become available
```

**Cause:** AWS is slow provisioning the NAT GW (occasionally takes 5+ minutes).

**Fix:** Re-run `terraform apply`  -  it is idempotent. Terraform will wait again from where it left off.

---

## 13. What Comes Next

The VPC module created here is the networking foundation for all subsequent lessons. The subnet IDs become inputs to EC2 and RDS deployments.

| Lesson | Uses This VPC's... |
|---|---|
| **06  -  EC2 Deployment** | Public subnet ID (`public_subnet_ids[0]`) |
| **07  -  RDS Database** | Private DB subnet IDs (`private_db_subnet_ids`) + VPC ID |
| **08  -  3-Tier Basic** | Public subnet (frontend), private-app subnets (backend) |
| **09  -  3-Tier Production** | All three tiers + `nat_gateway_public_ip` for firewall allowlisting |
| **12  -  Bastion Host** | Public subnet for Bastion, private-app for backend access |
| **13  -  Complete Production** | All outputs from this VPC module |

---

## Dependency Map

```
terraform.tfvars
      |
      v
Root variables.tf
      |  (all 8 variables passed to module)
      v
module "vpc" {source = "./modules/vpc"}
      |
      v
modules/vpc/main.tf
      |
      +-- aws_vpc.main
      |     |
      |     +-- aws_subnet.public[0,1]            (count=2, map_public_ip=true)
      |     +-- aws_subnet.private_app[0,1]       (count=2)
      |     +-- aws_subnet.private_db[0,1]        (count=2)
      |     +-- aws_internet_gateway.main
      |               |
      |               | (depends_on)
      |               v
      |     aws_eip.nat
      |               |
      |               v
      |     aws_nat_gateway.main                  (in public[0] only)
      |               |
      +-- aws_route_table.public           (route: 0.0.0.0/0 -> IGW)
      +-- aws_route_table.private_app      (route: 0.0.0.0/0 -> NAT GW)
      +-- aws_route_table.private_db       (no internet route)
      +-- aws_route_table_association.*    (6 associations: 2 per route table)
      |
      v
modules/vpc/outputs.tf
  vpc_id, vpc_cidr, public_subnet_ids[*],
  private_app_subnet_ids[*], private_db_subnet_ids[*],
  internet_gateway_id, nat_gateway_id, nat_gateway_public_ip
      |
      v
Root outputs.tf
  (passes all 8 module outputs to terraform output)
```

New patterns introduced in this lesson:
1. **`count` with `count.index`**  -  creates N identical-but-distinct resources from one block
2. **Splat `[*]`**  -  extracts one attribute from all instances of a counted resource
3. **`depends_on`**  -  explicit ordering when Terraform cannot infer the dependency from attributes
4. **Intentional no-route table**  -  security by omission (Private DB tier)
5. **`list(string)` variable type**  -  passing ordered collections as inputs

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
