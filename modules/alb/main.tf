# ==============================================================================
# Module: ALB (Application Load Balancer)
# Creates:
#   - Internet-facing ALB in public subnets
#   - Target Group: frontend (port 80)
#   - Target Group: backend  (port 3000)
#   - Listener: HTTP:80  → 301 redirect to HTTPS
#   - Listener: HTTPS:443 with path-based routing:
#       /api/*    → backend TG
#       /health   → backend TG
#       default/* → frontend TG
#   - Route53 A alias record → ALB
# ==============================================================================

# ------------------------------------------------------------------------------
# Application Load Balancer
# ------------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  # Access logs can be enabled by adding an S3 bucket
  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

# ------------------------------------------------------------------------------
# Target Group: Frontend (Nginx on port 80)
# ------------------------------------------------------------------------------
resource "aws_lb_target_group" "frontend" {
  name        = "${var.project_name}-${var.environment}-fe-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-tg"
  }
}

# ------------------------------------------------------------------------------
# Target Group: Backend (Node.js on port 3000)
# ------------------------------------------------------------------------------
resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-${var.environment}-be-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-backend-tg"
  }
}

# ------------------------------------------------------------------------------
# Target Group Attachments: Frontend instances
# ------------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "frontend" {
  count            = length(var.frontend_instance_ids)
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = var.frontend_instance_ids[count.index]
  port             = 80
}

# ------------------------------------------------------------------------------
# Target Group Attachments: Backend instances
# ------------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "backend" {
  count            = length(var.backend_instance_ids)
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = var.backend_instance_ids[count.index]
  port             = 3000
}

# ------------------------------------------------------------------------------
# Listener: HTTP:80 → Redirect to HTTPS
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ------------------------------------------------------------------------------
# Listener: HTTPS:443 — path-based routing
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  # Default: forward to frontend
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# Rule: /api/* → backend
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# Rule: /health → backend
resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/health"]
    }
  }
}

# ------------------------------------------------------------------------------
# Route53 A Alias record — bmi.ostaddevops.click → ALB
# ------------------------------------------------------------------------------
resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
