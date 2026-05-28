# -----------------------------------------------------------------------------
# ROOT VARIABLES
#
# Change terraform.tfvars to customise for your setup.
# Nothing in this file needs editing — add/change values in terraform.tfvars.
# -----------------------------------------------------------------------------

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  description = "Short prefix used on all resource names. Lowercase, hyphens ok."
  type        = string
  default     = "uplatform"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "cluster_name" {
  type    = string
  default = "uplatform-cluster"
}

# Network
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Single AZ by default. Add more CIDRs for multi-AZ — no code changes needed."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Must have same number of entries as public_subnet_cidrs."
  type        = list(string)
  default     = ["10.0.10.0/24"]
}

variable "isolated_subnet_cidrs" {
  description = "RDS subnets. No internet route. Must have same count as others."
  type        = list(string)
  default     = ["10.0.20.0/24"]
}

# Domain
variable "domain_name" {
  description = "Your domain. Route53 hosted zone must already exist."
  type        = string
}

# GitHub
variable "github_org" {
  description = "GitHub username or org (e.g. Jp2op)"
  type        = string
}

variable "github_repo" {
  description = "Repo name without owner (e.g. user-platform-v2)"
  type        = string
  default     = "user-platform-v2"
}

variable "github_oidc_provider_arn" {
  description = "From bootstrap output: terraform_pipeline_role_arn"
  type        = string
}

# EKS nodes
variable "node_instance_types" {
  description = "Multiple types let Spot pick cheapest available in the AZ."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_desired_size" { type = number; default = 2 }
variable "node_min_size"     { type = number; default = 1 }
variable "node_max_size"     { type = number; default = 4 }

# RDS
variable "rds_instance_class" {
  description = "db.t3.micro is free tier eligible."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_deletion_protection" {
  description = "Set false only when you intend to destroy the database."
  type        = bool
  default     = true
}

# Filled after kubernetes bootstrap creates the ALB
variable "alb_dns_name" {
  description = "Get with: kubectl get ingress -A. Leave empty on first apply."
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "ALB hosted zone ID. Fixed per region — ap-south-1 is ZP97RAFLXTNZK."
  type        = string
  default     = "ZP97RAFLXTNZK"
}
