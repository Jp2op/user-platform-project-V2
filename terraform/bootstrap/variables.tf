variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short name used as prefix for all resources. Lowercase, no spaces."
  type        = string
  default     = "uplatform"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric and hyphens only."
  }
}

variable "github_org" {
  description = "GitHub organization or username that owns the repo (e.g. Jp2op)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without owner (e.g. user-platform-v2)"
  type        = string
}
