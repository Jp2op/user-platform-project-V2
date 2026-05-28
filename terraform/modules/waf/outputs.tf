output "web_acl_arn" {
  description = "Associate this with your ALB via annotation in the Ingress or via aws_alb association"
  value       = aws_wafv2_web_acl.main.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.main.id
}
