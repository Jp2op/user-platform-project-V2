variable "project_name" { type = string }
variable "aws_region"   { type = string }
variable "cluster_name" {
  description = "EKS cluster name — used in subnet tags so ALB controller can discover them"
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One per AZ. Default is single AZ. Add more CIDRs for multi-AZ."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One per AZ. EKS nodes. Must match public_subnet_cidrs count."
  type        = list(string)
  default     = ["10.0.10.0/24"]
}

variable "isolated_subnet_cidrs" {
  description = "One per AZ. RDS. No internet route."
  type        = list(string)
  default     = ["10.0.20.0/24"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
