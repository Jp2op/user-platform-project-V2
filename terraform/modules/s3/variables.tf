variable "project_name" {
  type = string
}

variable "s3_kms_key_arn" {
  type = string
}

variable "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN for OAC bucket policy. Pass empty string initially."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
