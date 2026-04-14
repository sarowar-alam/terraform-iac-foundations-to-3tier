#!/bin/bash
# ==============================================================================
# frontend.sh — Frontend EC2 User Data
# Installs Nginx and serves the React production build.
#
# Phase 1: EC2 in PUBLIC subnet — Nginx proxies /api/* to backend private IP
# Phase 2: EC2 in PRIVATE subnet — ALB handles routing, Nginx serves static files only
#
# Terraform passes variables via templatefile()
# ==============================================================================
set -e

# Logging — simple redirect without pipefail-breaking process substitution
exec > /var/log/user-data.log 2>&1

echo "============================="
echo " BMI Frontend — User Data"
echo " Timestamp: $(date)"
echo "============================="

# Template variables injected by Terraform templatefile()
BACKEND_PRIVATE_IP="${backend_private_ip}"
PHASE="${phase}"  # "basic" or "production"

APP_DIR="/home/ubuntu/bmi-health-tracker"

# ------------------------------------------------------------------------------
# System update + dependencies
# ------------------------------------------------------------------------------
echo "[INFO] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git nginx software-properties-common ca-certificates gnupg

echo "[SUCCESS] Base packages installed"

# ------------------------------------------------------------------------------
# Install Node.js 18 via NodeSource
# ------------------------------------------------------------------------------
echo "[INFO] Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
echo "[SUCCESS] Node.js $(node -v) / npm $(npm -v) installed"

# ------------------------------------------------------------------------------
# Clone repository
# ------------------------------------------------------------------------------
echo "[INFO] Cloning application repository..."
if [ -d "$APP_DIR/.git" ]; then
    echo "[INFO] Repo already exists, pulling latest..."
    git -C "$APP_DIR" pull
else
    git clone https://github.com/sarowar-alam/terraform-iac-foundations-to-3tier.git "$APP_DIR"
fi
chown -R ubuntu:ubuntu "$APP_DIR"
echo "[SUCCESS] Repository ready"

# ------------------------------------------------------------------------------
# Build React app
# ------------------------------------------------------------------------------
echo "[INFO] Installing npm dependencies..."
cd "$APP_DIR/frontend"
npm install

echo "[INFO] Building React production bundle..."
npm run build

# Deploy build to Nginx web root
echo "[INFO] Deploying build to /var/www/html/..."
rm -rf /var/www/html/*
cp -r "$APP_DIR/frontend/dist/"* /var/www/html/
echo "[SUCCESS] React build deployed"

# ------------------------------------------------------------------------------
# Nginx configuration
# Phase 1 (basic): proxy /api/* and /health to backend private IP
# Phase 2 (production): ALB handles routing — Nginx serves static files only
# ------------------------------------------------------------------------------
echo "[INFO] Configuring Nginx (phase=$PHASE)..."

if [ "$PHASE" = "basic" ]; then
  cat > /etc/nginx/sites-available/bmi-app <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    location /api/ {
        proxy_pass         http://$BACKEND_PRIVATE_IP:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout    30s;
    }

    location /health {
        proxy_pass http://$BACKEND_PRIVATE_IP:3000/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
else
  # Phase 2: ALB handles /api/* and /health routing to backend
  # Nginx only serves the React SPA static files
  cat > /etc/nginx/sites-available/bmi-app <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    # ALB health check for frontend target group
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX
fi

ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "============================="
echo " Frontend deployed successfully"
echo " Phase: $PHASE"
echo " Timestamp: $(date)"
echo "============================="
