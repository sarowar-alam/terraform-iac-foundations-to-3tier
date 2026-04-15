# ==============================================================================
# Module: Security Groups
# Creates security groups for each tier with least-privilege rules.
#
# SG hierarchy:
#   alb-sg       → receives internet traffic (80, 443)
#   frontend-sg  → receives 80 from alb-sg (SSM replaces SSH)
#   backend-sg   → receives 3000 from alb-sg (SSM replaces SSH)
#   rds-sg       → receives 5432 from backend-sg only
# ==============================================================================

# ------------------------------------------------------------------------------
# ALB Security Group — internet-facing
# ------------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "ALB: allow HTTP and HTTPS from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

# ------------------------------------------------------------------------------
# Frontend Security Group
# Phase 1 (basic): 80/443 from 0.0.0.0/0
# Phase 2 (production): 80 from alb-sg only
# Controlled by var.frontend_public_access
# ------------------------------------------------------------------------------
resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-${var.environment}-frontend-sg"
  description = "Frontend EC2: HTTP from ALB (or internet in basic mode)"
  vpc_id      = var.vpc_id

  # Phase 2 (production): HTTP:80 from ALB SG only
  dynamic "ingress" {
    for_each = var.frontend_public_access ? [] : [1]
    content {
      description     = "HTTP from ALB only"
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  # Phase 1 (basic): HTTP:80 from internet directly
  dynamic "ingress" {
    for_each = var.frontend_public_access ? [1] : []
    content {
      description = "HTTP from internet (Phase 1)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-sg"
  }
}

# ------------------------------------------------------------------------------
# Backend Security Group
# Port 3000 from ALB only (never directly from internet)
# ------------------------------------------------------------------------------
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-${var.environment}-backend-sg"
  description = "Backend EC2: port 3000 from ALB, SSH from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Node.js API from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Phase 2 (production): also allow port 3000 from frontend SG via ALB routing
  # Phase 1 (basic): frontend EC2 calls backend directly
  dynamic "ingress" {
    for_each = var.frontend_public_access ? [1] : []
    content {
      description     = "Node.js API from frontend EC2 (Phase 1)"
      from_port       = 3000
      to_port         = 3000
      protocol        = "tcp"
      security_groups = [aws_security_group.frontend.id]
    }
  }

  egress {
    description = "Allow all outbound (RDS, Secrets Manager, NAT GW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-backend-sg"
  }
}

# ------------------------------------------------------------------------------
# RDS Security Group — database tier, private only
# ------------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "RDS PostgreSQL: port 5432 from backend EC2 only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from backend"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  }
}
