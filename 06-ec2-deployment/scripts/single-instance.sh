#!/bin/bash
# ==============================================================================
# single-instance.sh — Module 4 Automation
# Installs ALL THREE tiers on a single EC2 instance (Ubuntu 22.04)
# Mirrors what was done manually in Module 4.
#
# Tier 1: PostgreSQL 14 (database)
# Tier 2: Node.js + PM2 (backend API on port 3000)
# Tier 3: Nginx + React build (frontend on port 80)
#
# Used by: 06-ec2-deployment/
# ==============================================================================
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "======================================"
echo " BMI Health Tracker — Single Instance"
echo " Module 4 Automation via Terraform"
echo "======================================"

# ------------------------------------------------------------------------------
# System update
# ------------------------------------------------------------------------------
apt-get update -y
apt-get upgrade -y
apt-get install -y curl git unzip software-properties-common

# ------------------------------------------------------------------------------
# TIER 1: Install PostgreSQL 14
# ------------------------------------------------------------------------------
echo "[1/3] Installing PostgreSQL 14..."

apt-get install -y postgresql-14 postgresql-client-14

systemctl enable postgresql
systemctl start postgresql

# Create database and user
DB_NAME="bmidb"
DB_USER="bmi_user"
DB_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=')"

sudo -u postgres psql <<PSQL
CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
\c $DB_NAME
GRANT ALL ON SCHEMA public TO $DB_USER;
PSQL

# PostgreSQL config — allow local connections
PG_HBA="/etc/postgresql/14/main/pg_hba.conf"
echo "host    $DB_NAME    $DB_USER    127.0.0.1/32    md5" >> "$PG_HBA"
systemctl reload postgresql

echo "[1/3] PostgreSQL 14 ready. DB: $DB_NAME, User: $DB_USER"

# ------------------------------------------------------------------------------
# TIER 2: Install Node.js 18 + PM2 + Backend
# ------------------------------------------------------------------------------
echo "[2/3] Installing Node.js 18 and backend..."

# Node.js 18 via NodeSource
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g pm2

# Clone the repository
APP_DIR="/home/ubuntu/bmi-health-tracker"
git clone https://github.com/md-sarowar-alam/terraform-iac-foundations-to-3tier.git "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

# Install backend dependencies
cd "$APP_DIR/backend"
npm ci --production

# Create .env
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "localhost")
cat > "$APP_DIR/backend/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME
FRONTEND_URL=http://$PUBLIC_IP
EOF
chmod 600 "$APP_DIR/backend/.env"

# Run database migrations
echo "Running migrations..."
for sql_file in $(ls "$APP_DIR/backend/migrations/"*.sql | sort); do
  echo "  Applying: $sql_file"
  PGPASSWORD="$DB_PASSWORD" psql \
    -h 127.0.0.1 \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -f "$sql_file"
done

# Create PM2 log directory
mkdir -p "$APP_DIR/backend/logs"
chown -R ubuntu:ubuntu "$APP_DIR/backend/logs"

# Start with PM2 (run as ubuntu user)
sudo -u ubuntu bash -c "cd $APP_DIR/backend && pm2 start ecosystem.config.js --env production"
sudo -u ubuntu bash -c "pm2 save"

# PM2 startup on reboot
env PATH=$PATH:/usr/bin pm2 startup systemd -u ubuntu --hp /home/ubuntu
systemctl enable pm2-ubuntu

echo "[2/3] Backend running on port 3000"

# ------------------------------------------------------------------------------
# TIER 3: Install Nginx + Build and Serve React Frontend
# ------------------------------------------------------------------------------
echo "[3/3] Installing Nginx and building frontend..."

apt-get install -y nginx

# Install Node.js build deps for frontend
cd "$APP_DIR/frontend"
npm ci

# Build React app (Vite)
npm run build

# Deploy to Nginx web root
rm -rf /var/www/html/*
cp -r "$APP_DIR/frontend/dist/"* /var/www/html/

# Nginx config — serve SPA, proxy /api to backend
cat > /etc/nginx/sites-available/bmi-app <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html;

    server_name _;

    # Proxy API requests to Node.js backend
    location /api/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout    30s;
    }

    # Proxy /health to backend
    location /health {
        proxy_pass http://127.0.0.1:3000/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # React SPA — serve index.html for all routes
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

# Enable site
ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[3/3] Frontend deployed at http://$PUBLIC_IP"

echo ""
echo "========================================"
echo " Setup complete!"
echo " Application URL : http://$PUBLIC_IP"
echo " Backend health  : http://$PUBLIC_IP/health"
echo " Backend port    : 3000 (local)"
echo " Database        : $DB_NAME @ 127.0.0.1:5432"
echo "========================================"
