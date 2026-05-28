variable "project_name"    { type = string }
variable "cluster_name"    { type = string }
variable "aws_region"      { type = string }

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN — for IRSA pod roles"
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "EKS OIDC issuer URL — used to build StringEquals conditions"
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN — from bootstrap outputs"
  type        = string
}

variable "github_org"  { type = string }
variable "github_repo" { type = string }

variable "qa_secret_arn" {
  description = "Secrets Manager ARN for QA secret — ESO QA policy scoped to this"
  type        = string
}

variable "prod_secret_arn" {
  description = "Secrets Manager ARN for PROD secret"
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key used to encrypt secrets — ESO needs decrypt permission"
  type        = string
}

variable "loki_bucket_arn" {
  description = "S3 bucket ARN for Loki log storage"
  type        = string
}

variable "s3_kms_key_arn" {
  description = "KMS key used to encrypt S3 buckets"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
