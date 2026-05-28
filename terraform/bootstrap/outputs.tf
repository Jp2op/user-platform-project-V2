# After running bootstrap, copy these output values into:
#   terraform/backend.tf       → bucket, dynamodb_table, kms_key_id
#   .github/workflows/*.yaml   → role-to-assume (terraform_pipeline_role_arn)

output "state_bucket_name" {
  description = "Paste this into terraform/backend.tf as the bucket value"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  value = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_lock_table" {
  description = "Paste this into terraform/backend.tf as the dynamodb_table value"
  value       = aws_dynamodb_table.terraform_lock.name
}

output "kms_key_arn" {
  description = "Paste this into terraform/backend.tf as the kms_key_id value"
  value       = aws_kms_key.terraform_state.arn
}

output "terraform_pipeline_role_arn" {
  description = "Paste this into .github/workflows/terraform.yaml as role-to-assume"
  value       = aws_iam_role.terraform_pipeline.arn
}

output "developer_readonly_role_arn" {
  description = "Developers assume this role for read-only AWS access"
  value       = aws_iam_role.developer_readonly.arn
}

output "github_oidc_provider_arn" {
  description = "OIDC provider ARN — also used by app deploy roles in the main module"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "next_steps" {
  value = <<-EOT
    Bootstrap complete. Next steps:
    1. Copy state_bucket_name, dynamodb_lock_table, kms_key_arn into terraform/backend.tf
    2. Copy terraform_pipeline_role_arn into .github/workflows/terraform.yaml
    3. Copy github_oidc_provider_arn into terraform/terraform.tfvars as github_oidc_provider_arn
    4. Commit and push terraform/ — the pipeline takes over from here
    5. Never run terraform apply locally again
  EOT
}
