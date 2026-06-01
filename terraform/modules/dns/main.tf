# -----------------------------------------------------------------------------
# DNS MODULE
#
# Creates ACM certificate + Route53 records.
# Route53 records only created when alb_dns_name is provided.
# On first apply alb_dns_name is empty — only the cert gets created.
# After K8s bootstrap provides the ALB DNS, fill it in tfvars and re-apply.
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

resource "aws_route53_zone" "main" {
  name = var.domain_name
  tags = merge(var.tags, {
    Name = "${var.project_name}-zone"
  })
}

# -----------------------------------------------------------------------------
# ACM CERTIFICATE — wildcard covers domain + all subdomains
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-cert"
  })
}

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
  zone_id         = aws_route53_zone.main.zone_id
}