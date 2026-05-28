variable "project_name" { type = string }
variable "domain_name"  { type = string }

variable "alb_dns_name" {
  description = "ALB DNS name — get from kubectl get ingress -A after K8s bootstrap"
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "Fixed per region. ap-south-1 = ZP97RAFLXTNZK"
  type        = string
  default     = "ZP97RAFLXTNZK"
}

variable "tags" {
  type    = map(string)
  default = {}
}
