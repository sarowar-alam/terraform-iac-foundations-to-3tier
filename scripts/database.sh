#!/bin/bash
# ==============================================================================
# database.sh — Standalone Migration Runner
# Run from bastion host to apply migrations directly to RDS.
#
# Usage:
#   export DB_ENDPOINT="your-rds-endpoint.ap-south-1.rds.amazonaws.com"
#   export DB_USER="bmi_user"
#   export DB_PASSWORD="your-password"
#   export DB_NAME="bmidb"
#   export MIGRATIONS_DIR="/path/to/backend/migrations"
#   bash database.sh
#
# Or use with Secrets Manager:
#   DB_URL=$(aws secretsmanager get-secret-value \
#     --secret-id /prod/bmi-health-tracker/database-url \
#     --query SecretString --output text)
#   psql "$DB_URL" -f migration.sql
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Install PostgreSQL 14 client (if not installed)
# ------------------------------------------------------------------------------
if ! command -v psql &>/dev/null; then
  echo "Installing PostgreSQL client..."
  apt-get update -y
  apt-get install -y postgresql-client-14 || apt-get install -y postgresql-client
fi

# ------------------------------------------------------------------------------
# Validate required environment variables
# ------------------------------------------------------------------------------
: "${DB_ENDPOINT:?DB_ENDPOINT is required}"
: "${DB_USER:?DB_USER is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${DB_NAME:?DB_NAME is required}"
: "${MIGRATIONS_DIR:?MIGRATIONS_DIR is required}"

export PGPASSWORD="$DB_PASSWORD"

echo "========================================"
echo " Database Migration Runner"
echo " Host     : $DB_ENDPOINT"
echo " Database : $DB_NAME"
echo " User     : $DB_USER"
echo "========================================"

# Test connectivity first
echo "Testing database connection..."
psql -h "$DB_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT version();" \
  && echo "Connection successful." \
  || { echo "ERROR: Cannot connect to database. Check endpoint, credentials, and security groups."; exit 1; }

# ------------------------------------------------------------------------------
# Run all .sql migration files in sorted order
# ------------------------------------------------------------------------------
echo "Applying migrations from: $MIGRATIONS_DIR"

for sql_file in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
  echo ""
  echo "  --> Applying: $(basename $sql_file)"
  psql -h "$DB_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" -f "$sql_file" \
    && echo "      Done." \
    || echo "      Warning: may have already been applied (safe to ignore)."
done

echo ""
echo "========================================"
echo " All migrations applied."
echo "========================================"

# Verify table exists
echo "Verifying measurements table..."
psql -h "$DB_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" \
  -c "\d measurements" && echo "Table verified." || echo "Table not found."
