# ==============================================================================
# Module: Secrets Manager
# Creates AWS Secrets Manager secrets for database credentials.
# Passwords are randomly generated — never hardcoded.
#
# Secrets created:
#   /{environment}/bmi-health-tracker/db-password    → random password
#   /{environment}/bmi-health-tracker/database-url   → full connection string
# ==============================================================================

# ------------------------------------------------------------------------------
# Secret: DB Password
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "/${var.environment}/${var.project_name}/db-password"
  description             = "RDS PostgreSQL master password for ${var.project_name} ${var.environment}"
  recovery_window_in_days = var.recovery_window_days

  tags = {
    Name = "${var.project_name}-${var.environment}-db-password"
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password

  lifecycle {
    # Prevent Terraform from resetting the password on every apply
    ignore_changes = [secret_string]
  }
}

# ------------------------------------------------------------------------------
# Secret: Full DATABASE_URL connection string
# Used by backend.sh to set the DATABASE_URL env var without exposing password
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "database_url" {
  name                    = "/${var.environment}/${var.project_name}/database-url"
  description             = "PostgreSQL DATABASE_URL for ${var.project_name} ${var.environment} backend"
  recovery_window_in_days = var.recovery_window_days

  tags = {
    Name = "${var.project_name}-${var.environment}-database-url"
  }
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  # urlencode ensures special chars in the password don't break pg-connection-string URL parsing
  secret_string = "postgresql://${var.db_username}:${urlencode(var.db_password)}@${var.db_host}:5432/${var.db_name}"
}
