output "rds_endpoint" {
  description = "RDS hostname — used in connection strings"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  value = aws_db_instance.main.port
}

output "rds_identifier" {
  value = aws_db_instance.main.identifier
}

output "qa_secret_arn" {
  description = "Secrets Manager ARN for QA — used by IAM module to scope ESO permissions"
  value       = aws_secretsmanager_secret.qa.arn
}

output "prod_secret_arn" {
  description = "Secrets Manager ARN for PROD — used by IAM module to scope ESO permissions"
  value       = aws_secretsmanager_secret.prod.arn
}

output "qa_secret_name" {
  value = aws_secretsmanager_secret.qa.name
}

output "prod_secret_name" {
  value = aws_secretsmanager_secret.prod.name
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
