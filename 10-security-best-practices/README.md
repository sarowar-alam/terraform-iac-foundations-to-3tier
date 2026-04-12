# 10 — Security Best Practices

> **Module 7: Network Security as Code**
> Apply production security hardening to the 3-tier architecture: least-privilege IAM, encrypted storage, SSM Session Manager, and audit logging.

---

## What You Will Learn

- Security Groups: least-privilege ingress rules (no `0.0.0.0/0` on SSH)
- IAM least privilege: restrict `GetSecretValue` to **only** your project's secrets
- RDS encryption at rest: `storage_encrypted = true` (always enabled)
- `publicly_accessible = false` on RDS (enforced in module)
- AWS Systems Manager (SSM) Session Manager: SSH without opening port 22
- CloudWatch Logs integration via IAM role attachment
- Separating concerns: `attach_ssm_policy` and `attach_cloudwatch_policy` flags
- Security baseline outputs: reference for security review

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Security Layers                                              │
│                                                              │
│  Network Layer (Security Groups)                             │
│    bastion-sg:   port 22 ← YOUR_IP/32 only (never 0.0.0.0)  │
│    frontend-sg:  port 80 ← alb-sg only                      │
│    backend-sg:   port 3000 ← backend-sg only + port 22 ← bastion-sg │
│    rds-sg:       port 5432 ← backend-sg only                │
│                                                              │
│  Identity Layer (IAM)                                        │
│    backend role: GetSecretValue on /prod/bmi-health-tracker/* only │
│    + SSM managed instance (no port 22 needed)               │
│    + CloudWatch agent (ship logs)                           │
│                                                              │
│  Data Layer (RDS)                                            │
│    storage_encrypted = true  (AES-256)                      │
│    publicly_accessible = false                              │
│    Performance Insights enabled                             │
│                                                              │
│  Secret Management                                          │
│    Zero passwords in Terraform code                         │
│    Secrets Manager: /prod/bmi-health-tracker/db-password    │
└──────────────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
10-security-best-practices/
├── main.tf                  ← all modules, attach_ssm_policy=true, attach_cloudwatch_policy=true
├── variables.tf             ← allowed_ssh_cidr, domain_name
├── outputs.tf               ← security_summary output map for review
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
├── modules/
│   ├── vpc/
│   ├── security-group/      ← least-privilege SG rules
│   ├── iam/                 ← role with SSM + CloudWatch policies
│   ├── rds/                 ← encrypted, never public
│   ├── secrets/
│   └── ec2/
└── scripts/
    └── backend.sh
```

---

## Prerequisites

- [09-3tier-production](../09-3tier-production/README.md) completed

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
environment      = "prod"
key_name         = "sarowar-ostad-mumbai"
allowed_ssh_cidr = "YOUR_IP/32"   # curl ifconfig.me
domain_name      = "bmi.ostaddevops.click"
```

### Step 2: Deploy

```bash
terraform init
terraform plan
terraform apply
```

### Step 3: Review the Security Summary Output

```bash
terraform output security_summary
```

This outputs a map with all security settings for review:
```
{
  "iam_role"             = "bmi-health-tracker-prod-backend-role"
  "rds_encrypted"        = true
  "rds_publicly_access"  = false
  "secrets_path"         = "/prod/bmi-health-tracker/*"
  "ssh_restricted_to"    = "YOUR_IP/32"
  "ssm_enabled"          = true
}
```

### Step 4: Connect via SSM (No Port 22 Required)

With `attach_ssm_policy = true`, you can connect to the backend EC2 without SSH:

```bash
# List managed instances
aws ssm describe-instance-information \
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Name:ComputerName}" \
  --output table

# Connect via SSM Session Manager (no key pair, no port 22 needed!)
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx

# Once connected:
pm2 status
cat /etc/environment | grep -v PASSWORD
```

### Step 5: Verify IAM Restrictions

```bash
# Get the role name
ROLE=$(terraform output -raw iam_role_name)

# Show what the role can do
aws iam get-role-policy --role-name $ROLE --policy-name secrets-access | \
  python -m json.tool
# Should show: only GetSecretValue + DescribeSecret on /prod/bmi-health-tracker/* only
```

### Step 6: Verify RDS Encryption

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBName=='bmidb'].{Encrypted:StorageEncrypted,Public:PubliclyAccessible,ID:DBInstanceIdentifier}" \
  --output table
# Expected: Encrypted=True, Public=False
```

### Step 7: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### IAM Least Privilege
```hcl
# BAD — wildcard allows access to ALL secrets
"Resource": "arn:aws:secretsmanager:*:*:secret:*"

# GOOD — restricted to only this project's secrets
"Resource": "arn:aws:secretsmanager:ap-south-1:388779989543:secret:/prod/bmi-health-tracker/*"
```

The `modules/iam/` module uses `data.aws_caller_identity` to get the account ID dynamically — no hardcoded account numbers.

### SSM Session Manager vs SSH

| | SSH (Port 22) | SSM Session Manager |
|-|---------------|---------------------|
| Port required | 22 open in SG | None |
| Key pair required | Yes | No |
| Audit logs | None built-in | CloudTrail + S3 |
| Works in private subnet | Only via bastion | Yes (via SSM endpoint) |
| Setup | Zero config | `attach_ssm_policy = true` |

### Security Group Rules — No Wildcards
```hcl
# BAD — allows any IP to SSH
ingress {
  cidr_blocks = ["0.0.0.0/0"]
  from_port   = 22
}

# GOOD — restricted to your IP
ingress {
  cidr_blocks = [var.allowed_ssh_cidr]   # "x.x.x.x/32"
  from_port   = 22
}

# BEST — use Security Group reference instead of IP
ingress {
  security_groups = [aws_security_group.bastion.id]
  from_port       = 22
}
```

### Encryption at Rest
RDS `storage_encrypted = true` uses AWS KMS AES-256 encryption. The key is managed by AWS (`aws/rds`). For compliance requirements, you can specify a customer-managed KMS key with `kms_key_id`.

---

## Security Checklist

Run through this after every deployment:

```bash
# 1. No RDS public access
aws rds describe-db-instances --query "DBInstances[].PubliclyAccessible" --output text
# Expected: False

# 2. No SSH from 0.0.0.0/0
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*bastion*" \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" \
  --output text
# Should NOT contain 0.0.0.0/0

# 3. Secrets Manager has no plaintext passwords in Terraform state
grep -r "password" terraform.tfstate | grep -v "secret_id\|secret_string"
# Expected: no results

# 4. IAM role has no wildcards
aws iam get-role-policy --role-name $(terraform output -raw iam_role_name) \
  --policy-name secrets-access --query "PolicyDocument.Statement[0].Resource" \
  --output text
# Should be a specific ARN, not *
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Next Step

→ **[11-user-data-automation](../11-user-data-automation/README.md)** — deep dive into `templatefile()` and EC2 bootstrap automation.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
