# 07 — RDS Database

> **Module 7: Extract PostgreSQL into Managed RDS**
> First architectural split: pull the database off the EC2 into a managed AWS RDS PostgreSQL instance in a private subnet.

---

## What You Will Learn

- AWS RDS vs self-managed PostgreSQL on EC2 — when and why to choose RDS
- DB Subnet Group: the RDS networking requirement
- Why `publicly_accessible = false` is mandatory for production
- Encryption at rest with `storage_encrypted = true`
- AWS Secrets Manager: no passwords in Terraform code
- `random_password` resource: generate secure passwords automatically
- PostgreSQL parameter group: tuning max_connections, slow query logging
- Performance Insights for query monitoring (7-day free tier)

---

## Architecture

```
Internet
    │   (no direct access to RDS)
    │
VPC: 10.0.0.0/16
    │
    ├── Private-DB Subnets (10.0.5.0/24, 10.0.6.0/24)
    │       └── RDS PostgreSQL 14  (db.t3.micro)
    │               ↑ SG: allows 5432 from backend-sg only
    │
    └── DB Subnet Group   (spans both private-db subnets)

Secrets Manager:
    ├── /dev/bmi-health-tracker/db-password
    └── /dev/bmi-health-tracker/database-url
```

---

## Folder Structure

```
07-rds-database/
├── main.tf                  ← vpc + security-group + secrets + rds modules
├── variables.tf             ← db_instance_class, project_name, environment
├── outputs.tf               ← db_endpoint, db_host, database_url_secret_name
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
└── modules/
    ├── vpc/                 ← VPC module (self-contained copy)
    ├── security-group/      ← Security group module
    ├── secrets/             ← AWS Secrets Manager module
    └── rds/                 ← RDS PostgreSQL module
```

---

## Prerequisites

- [05-networking-vpc](../05-networking-vpc/README.md) understood (VPC layout)
- AWS CLI configured

---

## Step-by-Step Deployment

### Step 1: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region       = "ap-south-1"
project_name     = "bmi-health-tracker"
environment      = "dev"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "YOUR_IP/32"   # curl ifconfig.me
db_instance_class = "db.t3.micro"
```

### Step 2: Deploy

```bash
terraform init
terraform plan
terraform apply
```

This creates ~25 resources including VPC, subnets, RDS, and Secrets Manager secrets.
**RDS takes 5-10 minutes to provision.**

### Step 3: Verify Outputs

```bash
terraform output
```

Expected:
```
db_endpoint              = "bmi-health-tracker-dev.xxxxxxxx.ap-south-1.rds.amazonaws.com:5432"
db_host                  = "bmi-health-tracker-dev.xxxxxxxx.ap-south-1.rds.amazonaws.com"
db_port                  = 5432
db_name                  = "bmidb"
database_url_secret_name = "/dev/bmi-health-tracker/database-url"
note                     = "Database is in a PRIVATE subnet. Use bastion host or backend EC2 to connect."
```

### Step 4: Retrieve the Database Password

```bash
# Get the generated password from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id "/dev/bmi-health-tracker/db-password" \
  --query SecretString --output text

# Get the full DATABASE_URL
aws secretsmanager get-secret-value \
  --secret-id "/dev/bmi-health-tracker/database-url" \
  --query SecretString --output text
```

### Step 5: Verify RDS is Private

```bash
# Confirm publicly_accessible = false
aws rds describe-db-instances \
  --query "DBInstances[?DBName=='bmidb'].{ID:DBInstanceIdentifier,Public:PubliclyAccessible,Status:DBInstanceStatus}" \
  --output table
```

### Step 6: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### Why RDS instead of PostgreSQL on EC2?

| | PostgreSQL on EC2 (Module 4) | AWS RDS |
|-|------------------------------|---------|
| Backups | Manual | Automated daily |
| Upgrades | Manual | One-click |
| Monitoring | Manual setup | Performance Insights, CloudWatch built-in |
| Multi-AZ failover | Manual configuration | One checkbox |
| Management overhead | High | Low |

### DB Subnet Group
RDS requires a **DB Subnet Group** — a named collection of subnets that RDS can place its instances in. Best practice: use private-db subnets only.

```hcl
resource "aws_db_subnet_group" "this" {
  subnet_ids = var.subnet_ids   # private-db subnet IDs
}
```

### `publicly_accessible = false`
RDS instances should **never** be publicly accessible. Access goes through:
- Backend EC2 (application traffic)
- Bastion host (for manual admin)

### Secrets Manager design
```
random_password → generates a 16-char secure password
aws_secretsmanager_secret → stores /dev/bmi-health-tracker/db-password
aws_secretsmanager_secret → stores /dev/bmi-health-tracker/database-url
                             (postgresql://bmi_user:PASSWORD@HOST:5432/bmidb)
```

The `lifecycle { ignore_changes = [secret_string] }` block prevents Terraform from resetting the password on every `apply`.

### PostgreSQL Parameter Group
Tuning applied:
- `max_connections = 100` — appropriate for t3.micro
- `log_connections = on` — logs new connections
- `log_min_duration_statement = 1000` — logs queries taking > 1 second (slow query log)

---

## Connectivity Pattern

RDS is in a private subnet — you cannot connect to it directly from your laptop.

**Option 1: Via Backend EC2** (production pattern)
```bash
# Backend EC2 connects using DATABASE_URL from Secrets Manager
```

**Option 2: Via Bastion (manual admin)**
```bash
# SSH to bastion, then psql from there
ssh -i sarowar-ostad-mumbai.pem ubuntu@<BASTION_IP>

# On bastion:
DB_URL=$(aws secretsmanager get-secret-value \
  --secret-id "/dev/bmi-health-tracker/database-url" \
  --query SecretString --output text)
psql "$DB_URL"
```

---

## Clean Up

```bash
terraform destroy -auto-approve
# Note: Secrets Manager has recovery_window_days=0 for immediate deletion
```

---

## Next Step

→ **[08-3tier-basic](../08-3tier-basic/README.md)** — add frontend and backend EC2 instances to complete the 3-tier architecture (Module 7, Phase 1).

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
