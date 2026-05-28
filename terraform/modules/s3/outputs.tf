output "loki_bucket_id" {
  value = aws_s3_bucket.loki.id
}

output "loki_bucket_arn" {
  description = "Passed to IAM module to scope Loki's S3 write permissions"
  value       = aws_s3_bucket.loki.arn
}
