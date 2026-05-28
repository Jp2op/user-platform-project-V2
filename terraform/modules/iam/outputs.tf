output "eso_qa_role_arn" {
  description = "Annotate the eso-qa-sa Kubernetes service account with this"
  value       = aws_iam_role.eso_qa.arn
}

output "eso_prod_role_arn" {
  description = "Annotate the eso-prod-sa Kubernetes service account with this"
  value       = aws_iam_role.eso_prod.arn
}

output "alb_controller_role_arn" {
  description = "Annotate the aws-load-balancer-controller service account with this"
  value       = aws_iam_role.alb_controller.arn
}

output "loki_role_arn" {
  description = "Annotate the loki service account with this"
  value       = aws_iam_role.loki.arn
}

output "github_qa_deploy_role_arn" {
  description = "Paste into GitHub secret AWS_ROLE_TO_ASSUME (QA pipeline)"
  value       = aws_iam_role.github_qa_deploy.arn
}

output "github_prod_deploy_role_arn" {
  description = "Paste into GitHub secret AWS_ROLE_TO_ASSUME_PROD (PROD pipeline)"
  value       = aws_iam_role.github_prod_deploy.arn
}
