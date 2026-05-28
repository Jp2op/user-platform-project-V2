output "certificate_arn" {
  description = "Used in ALB ingress annotation: alb.ingress.kubernetes.io/certificate-arn"
  value       = aws_acm_certificate_validation.main.certificate_arn
}

output "hosted_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
