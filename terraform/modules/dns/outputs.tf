output "certificate_arn" {
  description = "Used in ALB ingress annotation: alb.ingress.kubernetes.io/certificate-arn"
  value       = aws_acm_certificate.main.arn
}

output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "nameservers" {
  description = "Set these as nameservers in GoDaddy"
  value       = aws_route53_zone.main.name_servers
}