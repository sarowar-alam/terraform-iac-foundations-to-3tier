# 11 — User Data Automation

> **Module 8: `templatefile()` and EC2 Bootstrap Scripts**
> Deep dive into EC2 `user_data` automation using Terraform's `templatefile()` function. Understand how Terraform injects runtime values into shell scripts.

---

## What You Will Learn

- `user_data` and cloud-init: how EC2 executes scripts on first boot
- `file()` vs `templatefile()` — when to use which
- Template variables: inject Terraform-computed values into shell scripts
- Cloud-init log monitoring: `/var/log/user-data.log`
- Understanding the template rendering order (plan time vs apply time)
- Debugging user_data failures
- Why user_data only runs once (and how to re-run it manually)

---

## Architecture

```
Terraform Plan Time:
  templatefile("scripts/backend.sh", {
    database_url_secret_name = "/prod/bmi-health-tracker/database-url"
    frontend_url             = "https://bmi.ostaddevops.click"
    environment              = "prod"
    aws_region               = "ap-south-1"
  })
  └── Renders backend.sh with real values substituted

Apply Time:
  AWS receives the rendered shell script as user_data
  EC2 instance boots → cloud-init runs the script once
  └── Installs Node.js, PM2, fetches DB secret from Secrets Manager, starts app
```

---

## The Template Files

### `scripts/backend.sh` — Template Variables

| Template Variable | Value at Deploy Time | Source |
|---|---|---|
| `${database_url_secret_name}` | `/prod/bmi-health-tracker/database-url` | `module.secrets` output |
| `${frontend_url}` | `https://bmi.ostaddevops.click` | `var.domain_name` |
| `${environment}` | `prod` | `var.environment` |
| `${aws_region}` | `ap-south-1` | `var.aws_region` |

### `scripts/frontend.sh` — Template Variables

| Template Variable | Value at Deploy Time | Source |
|---|---|---|
| `${backend_private_ip}` | `10.0.3.x` | `module.backend.private_ip` |
| `${phase}` | `production` | hardcoded string |

---

## Folder Structure

```
11-user-data-automation/
├── main.tf                  ← shows templatefile() calls explicitly, outputs template_vars_sent
├── variables.tf             ← domain_name, environment, etc.
├── outputs.tf               ← template_vars_sent_to_backend, user_data_preview (base64)
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
├── modules/
│   ├── vpc/, security-group/, iam/, rds/, secrets/, ec2/
└── scripts/
    ├── backend.sh           ← template with ${variable_name} placeholders
    └── frontend.sh          ← template with ${backend_private_ip}, ${phase}
```

---

## Prerequisites

- [10-security-best-practices](../10-security-best-practices/README.md) completed

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

### Step 2: Preview the Template

Before deploying, understand what `templatefile()` will produce:

```bash
# Plan only — see what variables will be sent to the script
terraform init
terraform plan

# After plan, see the template vars in the output
terraform output template_vars_sent_to_backend
```

### Step 3: Deploy

```bash
terraform apply
```

### Step 4: Monitor Script Execution

```bash
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)

# SSH through bastion to backend
ssh -i sarowar-ostad-mumbai.pem -J ubuntu@$BASTION ubuntu@$BACKEND

# Watch the user_data script executing in real time
sudo tail -f /var/log/user-data.log

# Check if cloud-init finished
sudo cloud-init status
# Expected: status: done
```

### Step 5: Verify Template Variables Were Injected

```bash
# SSH to backend and inspect what was injected
cat /etc/environment
# Expected:
# ENVIRONMENT=prod
# AWS_REGION=ap-south-1

# Check the secret was fetched correctly
pm2 logs bmi-backend --lines 20
# Should show: "Connected to database" or similar
```

### Step 6: See the Rendered Script (Base64 in AWS)

```bash
# AWS stores user_data as base64
aws ec2 describe-instance-attribute \
  --instance-id $(terraform output -raw backend_instance_id) \
  --attribute userData \
  --query "UserData.Value" \
  --output text | base64 --decode | head -40
# Shows the actual rendered script that ran on the instance
```

### Step 7: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### `file()` vs `templatefile()`

```hcl
# file() — reads script verbatim, NO variable substitution
user_data = file("${path.module}/scripts/init.sh")

# templatefile() — renders template, substitutes ${var} placeholders
user_data = templatefile("${path.module}/scripts/backend.sh", {
  database_url_secret_name = "my-secret-name"
  environment              = var.environment
})
```

Use `file()` for static scripts. Use `templatefile()` when the script needs Terraform-computed values like resource IDs, IP addresses, or secret names.

### Template Variable Syntax in Shell Scripts

In `backend.sh`:
```bash
# ${var} in templatefile context is Terraform syntax
SECRET_NAME="${database_url_secret_name}"  # replaced by templatefile()
ENVIRONMENT="${environment}"               # replaced by templatefile()

# IMPORTANT: Regular bash variables use $VAR or ${VAR}
# To use a literal dollar sign in the template, escape it: $${VAR}
DATABASE_URL=$$(aws secretsmanager get-secret-value ...)  # $$ → $ in rendered output
```

### Template Rendering Order

```
1. terraform plan
   └── Terraform evaluates templatefile()
       └── All template variables must be known at plan time
           └── If a variable is "computed" (not known until apply), it shows as "(known after apply)"

2. terraform apply
   └── Real values substituted → rendered script string
   └── Stored in EC2 user_data (base64 encoded)
   └── EC2 boots → cloud-init decodes and runs the script
```

### cloud-init Logs

```bash
# Primary user_data log
sudo cat /var/log/user-data.log

# Cloud-init detailed log
sudo cat /var/log/cloud-init.log
sudo cat /var/log/cloud-init-output.log

# Check cloud-init status
sudo cloud-init status --long
```

### Re-running user_data (for troubleshooting only)

```bash
# user_data runs ONCE on first boot. To re-run manually:
sudo bash /var/lib/cloud/instance/scripts/part-001
```

---

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| App not running after 10 min | user_data script failed | Check `/var/log/user-data.log` |
| `${var_name}` appears literally in script | Used `file()` instead of `templatefile()` | Switch to `templatefile()` |
| `$PATH` variable missing | `$PATH` was treated as template var | Escape as `$$PATH` in template |
| Secret not found | IAM role not attached | Check `iam_instance_profile` is set |

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Next Step

→ **[12-bastion-host](../12-bastion-host/README.md)** — secure SSH access patterns with ProxyJump and `~/.ssh/config`.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
