output "ebs_key_arn" {
  description = "KMS key ARN for EBS encryption — pass to EKS and StorageClass"
  value       = aws_kms_key.ebs.arn
}

output "ebs_key_id" {
  value = aws_kms_key.ebs.key_id
}

output "rds_key_arn" {
  description = "KMS key ARN for RDS encryption — pass to RDS module"
  value       = aws_kms_key.rds.arn
}

output "secrets_key_arn" {
  description = "KMS key ARN for Secrets Manager — pass to RDS module for secret encryption"
  value       = aws_kms_key.secrets.arn
}

output "s3_key_arn" {
  description = "KMS key ARN for S3 bucket encryption — pass to S3 module"
  value       = aws_kms_key.s3.arn
}
