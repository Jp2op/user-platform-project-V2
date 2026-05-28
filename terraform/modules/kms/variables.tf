variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all KMS resources"
  type        = map(string)
  default     = {}
}
