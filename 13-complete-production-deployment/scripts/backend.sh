#!/bin/bash
# ==============================================================================
# backend.sh — Backend EC2 User Data
# Installs Node.js 18 + PM2, clones the app, fetches DATABASE_URL from
# AWS Secrets Manager, runs migrations, and starts the backend with PM2.
#
# Template variables injected by Terraform templatefile():
#   ${database_url_secret_name}  — Secrets Manager secret name
#   ${frontend_url}              — CORS allowed origin (https://bmi.ostaddevops.click)
#   ${environment}               — dev / staging / prod
#   ${aws_region}                — ap-south-1
# ==============================================================================
set -e
exec > /var/log/user-data.log 2>&1

echo "============================="
echo " BMI Backend — User Data"
echo "============================="

DATABASE_URL_SECRET="${database_url_secret_name}"
FRONTEND_URL="${frontend_url}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"

# ------------------------------------------------------------------------------
# System update + dependencies
# ------------------------------------------------------------------------------
echo "[INFO] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git unzip software-properties-common
echo "[SUCCESS] Base packages installed"

# AWS CLI v2 — for Secrets Manager calls
if ! command -v aws &>/dev/null; then
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# Node.js 18
echo "[INFO] Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y -qq nodejs
echo "[SUCCESS] Node.js $(node -v) / npm $(npm -v) installed"

# PM2 — process manager
npm install -g pm2

# PostgreSQL client — for running migrations
echo "[INFO] Installing PostgreSQL client..."
apt-get install -y -qq postgresql-client-14 || apt-get install -y -qq postgresql-client
echo "[SUCCESS] PostgreSQL client installed"

# ------------------------------------------------------------------------------
# Fetch DATABASE_URL from AWS Secrets Manager
# The EC2 IAM instance profile grants secretsmanager:GetSecretValue
# ------------------------------------------------------------------------------
echo "Fetching DATABASE_URL from Secrets Manager..."
DATABASE_URL=$(aws secretsmanager get-secret-value \
  --secret-id "$DATABASE_URL_SECRET" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)

if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: Failed to retrieve DATABASE_URL from Secrets Manager"
  exit 1
fi

echo "Database URL retrieved successfully."

# ------------------------------------------------------------------------------
# Clone repository
# ------------------------------------------------------------------------------
echo "[INFO] Cloning application repository..."
APP_DIR="/home/ubuntu/bmi-health-tracker"
if [ -d "$APP_DIR/.git" ]; then
  echo "[INFO] Repo already exists, pulling latest..."
  git -C "$APP_DIR" pull
else
  git clone https://github.com/sarowar-alam/terraform-iac-foundations-to-3tier.git "$APP_DIR"
fi
chown -R ubuntu:ubuntu "$APP_DIR"
echo "[SUCCESS] Repository ready"

# ------------------------------------------------------------------------------
# Install backend dependencies
# ------------------------------------------------------------------------------
cd "$APP_DIR/backend"
npm install --production

# ------------------------------------------------------------------------------
# Write .env (DATABASE_URL from Secrets Manager — never hardcoded)
# ------------------------------------------------------------------------------
cat > "$APP_DIR/backend/.env" <<EOF
NODE_ENV=$ENVIRONMENT
PORT=3000
DATABASE_URL=$DATABASE_URL
FRONTEND_URL=$FRONTEND_URL
EOF
chmod 600 "$APP_DIR/backend/.env"
chown ubuntu:ubuntu "$APP_DIR/backend/.env"

# ------------------------------------------------------------------------------
# Run database migrations (idempotent — safe to re-run)
# ------------------------------------------------------------------------------
echo "Running database migrations..."
for sql_file in $(ls "$APP_DIR/backend/migrations/"*.sql | sort); do
  echo "  Applying: $(basename $sql_file)"
  psql "$DATABASE_URL" -f "$sql_file" || echo "  Warning: migration may have already run"
done

# ------------------------------------------------------------------------------
# Create log directory and start PM2
# ------------------------------------------------------------------------------
mkdir -p "$APP_DIR/backend/logs"
chown -R ubuntu:ubuntu "$APP_DIR/backend/logs"

# Start PM2 as ubuntu user
export PM2_HOME=/home/ubuntu/.pm2
sudo -u ubuntu bash -c "export PM2_HOME=/home/ubuntu/.pm2; cd $APP_DIR/backend && pm2 start ecosystem.config.js --env production"
sudo -u ubuntu bash -c "export PM2_HOME=/home/ubuntu/.pm2; pm2 save"

# Configure PM2 to start on boot (as ubuntu user, passing correct PATH)
sudo -u ubuntu bash -c "export PM2_HOME=/home/ubuntu/.pm2; pm2 startup systemd -u ubuntu --hp /home/ubuntu" | grep "sudo env" | bash || true
systemctl enable pm2-ubuntu 2>/dev/null || true

echo ""
echo "====================================="
echo " Backend started on port 3000"
echo " Environment: $ENVIRONMENT"
echo " CORS origin: $FRONTEND_URL"
echo "====================================="
