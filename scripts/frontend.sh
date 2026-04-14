#!/bin/bash
# ==============================================================================
# frontend.sh — Frontend EC2 User Data
# Installs Nginx and serves the React production build.
# Used in 3-tier architectures (Phase 1 and Phase 2).
#
# Phase 1: EC2 in PUBLIC subnet — Nginx proxies /api/* to backend private IP
# Phase 2: EC2 in PRIVATE subnet — ALB handles routing, Nginx serves static files only
#
# Terraform passes BACKEND_PRIVATE_IP via templatefile()
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

# Node.js 18 for building the React app
echo "[INFO] Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
echo "[SUCCESS] Node.js $(node -v) / npm $(npm -v) installed"

# ------------------------------------------------------------------------------
# Clone repository and build React app
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

echo "[INFO] Installing npm dependencies..."
cd "$APP_DIR/frontend"
npm install

echo "[INFO] Building React production bundle..."
npm run build

# Deploy build to Nginx web root
rm -rf /var/www/html/*
cp -r "$APP_DIR/frontend/dist/"* /var/www/html/

# ------------------------------------------------------------------------------
# Nginx configuration
# Phase 1 (basic): proxy /api/* to backend private IP
# Phase 2 (production): ALB handles /api/* routing — Nginx serves static only
# ------------------------------------------------------------------------------
if [ "$PHASE" = "basic" ]; then
  # Phase 1: directly proxy to backend
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
  # Phase 2: ALB handles all routing — serve static files only
  cat > /etc/nginx/sites-available/bmi-app <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    # Health check endpoint for ALB target group
    location /health-fe {
        return 200 'ok';
        add_header Content-Type text/plain;
    }

    # React SPA routing
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

echo "Frontend deployed. Phase: $PHASE"
