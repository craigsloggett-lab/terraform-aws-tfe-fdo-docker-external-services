resource "aws_lb" "tfe" {
  name                       = var.lb_name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = module.vpc.public_subnets
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_listener" "tfe" {
  load_balancer_arn = aws_lb.tfe.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.tfe.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tfe.arn
  }
}

resource "aws_lb_target_group" "tfe" {
  name     = var.lb_target_group_name
  port     = 443
  protocol = "HTTPS"
  vpc_id   = module.vpc.vpc_id

  health_check {
    protocol            = "HTTPS"
    path                = "/_health_check"
    healthy_threshold   = 2
    unhealthy_threshold = 7
    timeout             = 5
    interval            = 30
    matcher             = 200
  }
}
