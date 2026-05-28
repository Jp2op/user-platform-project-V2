variable "project_name"  { type = string }
variable "vpc_id"        { type = string }

variable "isolated_subnet_ids" {
  description = "Subnets with no internet route — where RDS lives"
  type        = list(string)
}

variable "eks_node_security_group_id" {
  description = "EKS node SG — only source allowed to connect to RDS on 3306"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for RDS storage encryption"
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key for Secrets Manager encryption"
  type        = string
}

variable "instance_class" {
  description = "RDS instance type"
  type        = string
  default     = "db.t3.micro"
}

variable "multi_az" {
  description = "Enable Multi-AZ standby. Set true for production SLA."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Prevent accidental RDS deletion. Set false only to destroy."
  type        = bool
  default     = true
}

variable "qa_database_name" {
  type    = string
  default = "qa_db"
}

variable "prod_database_name" {
  type    = string
  default = "prod_db"
}

variable "qa_db_username" {
  type    = string
  default = "qa_appuser"
}

variable "prod_db_username" {
  type    = string
  default = "prod_appuser"
}

variable "tags" {
  type    = map(string)
  default = {}
}
