# -----------------------------------------------------------------------------
# OUTPUTS
# Run: terraform output  after apply.
# Copy values into GitHub secrets and terraform.tfvars as instructed.
# -----------------------------------------------------------------------------

# Cluster
output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }

output "kubeconfig_command" {
  description = "Run this before kubernetes/bootstrap/bootstrap.sh"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# RDS
output "rds_endpoint"     { value = module.rds.rds_endpoint }
output "qa_secret_name"   { value = module.rds.qa_secret_name }
output "prod_secret_name" { value = module.rds.prod_secret_name }

# S3
output "loki_bucket" { value = module.s3.loki_bucket_id }

# ACM
output "certificate_arn" {
  description = "Used in ALB ingress annotation: alb.ingress.kubernetes.io/certificate-arn"
  value       = module.dns.certificate_arn
}

# WAF
output "waf_acl_arn" {
  description = "Used in ALB ingress annotation: alb.ingress.kubernetes.io/wafv2-acl-arn"
  value       = module.waf.web_acl_arn
}

# IAM — paste into GitHub repo secrets
output "github_qa_deploy_role_arn" {
  description = "GitHub secret → AWS_ROLE_TO_ASSUME"
  value       = module.iam.github_qa_deploy_role_arn
}

output "github_prod_deploy_role_arn" {
  description = "GitHub secret → AWS_ROLE_TO_ASSUME_PROD"
  value       = module.iam.github_prod_deploy_role_arn
}

# IAM — paste into kubernetes/bootstrap/bootstrap.sh
output "alb_controller_role_arn" { value = module.iam.alb_controller_role_arn }
output "eso_qa_role_arn"         { value = module.iam.eso_qa_role_arn }
output "eso_prod_role_arn"       { value = module.iam.eso_prod_role_arn }
output "loki_role_arn"           { value = module.iam.loki_role_arn }

output "next_steps" {
  value = <<-EOT

    Terraform apply complete. What to do next:

    1. Run kubeconfig_command to configure kubectl
    2. Copy the role ARNs above into kubernetes/bootstrap/bootstrap.sh
    3. Copy github_qa/prod_deploy_role_arn into GitHub repo secrets
    4. Run: bash kubernetes/bootstrap/bootstrap.sh
    5. Get ALB DNS: kubectl get ingress -A
    6. Fill alb_dns_name in terraform.tfvars → push → pipeline re-applies DNS records

  EOT
}
