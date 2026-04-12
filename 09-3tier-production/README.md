# 09 — 3-Tier Production Architecture (Module 7 Phase 2)

> **Module 7 Phase 2: Everything Private + Application Load Balancer**
> Move the frontend to a private subnet. The ALB becomes the single internet-facing entry point. HTTPS with ACM certificate. Custom domain via Route53.

---

## What You Will Learn

- Application Load Balancer (ALB): internet-facing, HTTPS termination
- Target Groups: register EC2 instances for load balancing
- ALB Listener Rules: path-based routing (`/api/*` → backend, `/*` → frontend)
- HTTP → HTTPS redirect (301) using ALB listener
- ACM TLS certificate: no manual certificate management
- Route53 A alias record: `bmi.ostaddevops.click` → ALB DNS name
- Why the frontend moves to a **private** subnet in Phase 2
- `frontend_public_access = false`: security group change from Phase 1

---

## Architecture

```
Internet
    │
    ▼ HTTPS:443 / HTTP:80 (redirect)
Application Load Balancer  [Public Subnets: 10.0.1.0/24, 10.0.2.0/24]
    │  Certificate: ACM arn:aws:acm:ap-south-1:388779989543:certificate/...
    │  Domain: bmi.ostaddevops.click (Route53 alias)
    │
    ├──── /api/*  ──────►  Backend TG  ──►  Backend EC2  :3000  [Private-App]
    └──── /*      ──────►  Frontend TG ──►  Frontend EC2 :80   [Private-App]

Bastion EC2  [Public Subnet]  ← SSH jump server
    └── SSH → Backend  (ProxyJump)
    └── SSH → Frontend (ProxyJump)

RDS PostgreSQL  [Private-DB Subnets]
NAT Gateway     [Public Subnet]  ← private instances get outbound internet
```

---

## Key Difference from Phase 1

| | Phase 1 (08-3tier-basic) | Phase 2 (this folder) |
|-|--------------------------|----------------------|
| `frontend_public_access` | `true` | `false` |
| Frontend location | PUBLIC subnet | **PRIVATE subnet** |
| Frontend SG | Port 80 open to internet | **Port 80 from ALB SG only** |
| ALB | None | **Required** |
| Protocol | HTTP | **HTTPS with ACM cert** |
| URL | `http://IP` | **`https://bmi.ostaddevops.click`** |

---

## Folder Structure

```
09-3tier-production/
├── main.tf                  ← all modules, frontend_public_access=false, alb module
├── variables.tf             ← certificate_arn, hosted_zone_id, domain_name, etc.
├── outputs.tf               ← app_url (HTTPS), alb_dns, ssh commands, health_check
├── terraform.tfvars.example ← copy → terraform.tfvars
├── README.md                ← this file
├── modules/
│   ├── vpc/
│   ├── security-group/      ← frontend_public_access=false changes SG rules
│   ├── iam/
│   ├── rds/
│   ├── secrets/
│   ├── ec2/
│   └── alb/                 ← ALB + TGs + HTTPS listener + Route53 record
└── scripts/
    ├── backend.sh
    └── frontend.sh          ← phase=production (no Nginx proxy — ALB handles routing)
```

---

## Prerequisites

- [08-3tier-basic](../08-3tier-basic/README.md) completed
- ACM certificate already created in ap-south-1 (pre-provisioned)
- Route53 hosted zone for `ostaddevops.click` exists

---

## Step-by-Step Deployment

### Step 1: Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region              = "ap-south-1"
project_name            = "bmi-health-tracker"
environment             = "production"
key_name                = "sarowar-ostad-mumbai"
allowed_ssh_cidr        = "YOUR_IP/32"   # curl ifconfig.me
frontend_instance_type  = "t3.medium"
backend_instance_type   = "t3.small"
db_instance_class       = "db.t3.micro"

# Pre-provisioned — do not change
certificate_arn = "arn:aws:acm:ap-south-1:388779989543:certificate/c5e5f2a5-c678-4799-b355-765c13584fe0"
hosted_zone_id  = "Z1019653XLWIJ02C53P5"
domain_name     = "bmi.ostaddevops.click"
```

### Step 2: Deploy

```bash
terraform init
terraform plan
terraform apply
```

Expect ~40 resources. RDS takes 8-10 min. EC2 user_data takes another 3-5 min.

### Step 3: Wait and Verify

```bash
# Check ALB is active
terraform output alb_dns_name

# Wait for EC2 instances to pass health checks (~3-5 min after apply)
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw frontend_tg_arn) \
  --query "TargetHealthDescriptions[].{Instance:Target.Id,Health:TargetHealth.State}" \
  --output table
```

### Step 4: Test the Application

```bash
# HTTPS via domain name
curl https://bmi.ostaddevops.click/health
# Expected: {"status":"ok","environment":"production"}

# API endpoint
curl https://bmi.ostaddevops.click/api/health

# HTTP should redirect to HTTPS (301)
curl -I http://bmi.ostaddevops.click
# Expected: HTTP/1.1 301 Moved Permanently, Location: https://...

# Direct frontend IP should NOT be reachable (private subnet)
# curl http://<frontend_private_ip>   ← times out (no public IP)
```

### Step 5: SSH via Bastion

```bash
BASTION=$(terraform output -raw bastion_public_ip)
BACKEND=$(terraform output -raw backend_private_ip)
FRONTEND=$(terraform output -raw frontend_private_ip)

# SSH to backend
ssh -i sarowar-ostad-mumbai.pem -J ubuntu@$BASTION ubuntu@$BACKEND

# SSH to frontend
ssh -i sarowar-ostad-mumbai.pem -J ubuntu@$BASTION ubuntu@$FRONTEND

# Check Nginx on frontend
sudo nginx -t
sudo systemctl status nginx
```

### Step 6: Clean Up

```bash
terraform destroy
```

---

## Key Concepts Explained

### ALB Listener Rules (Path Routing)

```
Listener HTTPS:443
  ├── Rule priority 10:  /api/*  → Backend Target Group   (port 3000)
  ├── Rule priority 20:  /health → Backend Target Group   (port 3000)
  └── Default:           /*      → Frontend Target Group  (port 80)
```

The ALB evaluates rules in priority order. Priority 10 matches first.

### HTTP → HTTPS Redirect
```
Listener HTTP:80
  └── Default action: redirect to https://#{host}/#{path}?#{query}  (301 permanent)
```
Users who type `http://` are automatically redirected.

### Frontend in Private Subnet
In Phase 1, the frontend EC2 had a public IP. Any user with that IP could bypass the ALB.
In Phase 2:
- Frontend is in a **private subnet** (no public IP)
- Frontend SG allows port 80 **only from the ALB security group**
- The only path to reach the frontend is through the ALB

### Target Group Health Checks
```
Frontend TG: GET / on port 80, expect HTTP 200
Backend TG:  GET /health on port 3000, expect HTTP 200
```
ALB only sends traffic to instances that are healthy.

### Route53 Alias vs CNAME
```hcl
resource "aws_route53_record" "app" {
  type = "A"
  alias {
    name                   = aws_lb.this.dns_name  # ALB DNS
    zone_id                = aws_lb.this.zone_id   # ALB hosted zone
    evaluate_target_health = true
  }
}
```
An **Alias A record** is preferred over CNAME for AWS resources — it's free and resolves at the zone apex (e.g., `example.com` not just `www.example.com`).

---

## Verify Full Flow

```bash
# 1. DNS resolves to ALB
nslookup bmi.ostaddevops.click

# 2. HTTPS certificate valid
curl -v https://bmi.ostaddevops.click 2>&1 | grep "SSL certificate"

# 3. API returns data
curl https://bmi.ostaddevops.click/api/measurements

# 4. Frontend serves React app
curl -s https://bmi.ostaddevops.click | head -20

# 5. HTTP redirects to HTTPS
curl -I http://bmi.ostaddevops.click
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Next Step

→ **[10-security-best-practices](../10-security-best-practices/README.md)** — audit and harden the architecture's security posture.

---

*Md. Sarowar Alam*
Lead DevOps Engineer, WPP Production
📧 Email: sarowar@hotmail.com
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
