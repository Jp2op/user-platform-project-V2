# -----------------------------------------------------------------------------
# DNS MODULE
#
# Creates:
#   - ACM certificate for your domain (DNS validated, wildcard covers subdomains)
#   - Route53 validation records (Terraform creates these automatically)
#   - Route53 A record: domain → ALB  (app)
#   - Route53 A record: grafana.domain → ALB  (monitoring)
#
# No CloudFront — frontend is served from Nginx in Kubernetes via the same ALB.
#
# Pre-requisite: Route53 hosted zone for your domain must already exist.
# Terraform fetches it via data source — it does not create it.
# (Buying/delegating a domain is a manual one-time step.)
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# Fetch the existing hosted zone by domain name
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# -----------------------------------------------------------------------------
# ACM CERTIFICATE
# Wildcard covers: domain.com + *.domain.com (all subdomains)
# DNS validated — Terraform creates the CNAME records automatically.
# Certificate is REGIONAL (ap-south-1) for use with ALB.
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    # Create replacement before destroying old cert — zero downtime rotation
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-cert"
  })
}

# Terraform creates these CNAME records in Route53 to prove domain ownership
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# Wait for ACM to validate before outputting the cert ARN
# This can take 1-5 minutes
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# -----------------------------------------------------------------------------
# ROUTE53 RECORDS
# Both point to the same ALB — routing to the right backend happens at
# the ALB listener level via host-based routing rules.
# -----------------------------------------------------------------------------

# Root domain → ALB (serves frontend Nginx and /api/* backend)
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# www → ALB
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# grafana subdomain → ALB (ALB routes to monitoring namespace by hostname)
resource "aws_route53_record" "grafana" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "grafana.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
