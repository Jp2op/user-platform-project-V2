variable "project_name" { type = string }
variable "cluster_name"  { type = string }
variable "vpc_id"        { type = string }

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for encrypting Kubernetes secrets in etcd"
  type        = string
}


variable "ebs_kms_key_arn" {
  description = "KMS key for encrypting node EBS volumes"
  type        = string
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. ON_DEMAND is more expensive but launches immediately. SPOT saves ~70% but can be slow or unavailable."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}


variable "node_instance_types" {
  description = "EC2 instance types for the node group. List allows Spot to pick cheapest available."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "api_server_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API server. Default: open. Restrict to your IP for tighter security."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}