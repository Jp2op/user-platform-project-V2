# -----------------------------------------------------------------------------
# ROOT MODULE
#
# AWS infrastructure only. Terraform stops here.
# Everything inside Kubernetes is handled by kubernetes/ layer.
#
# Strict rule: no helm provider, no kubernetes provider, no kubectl calls.
#
# Dependency order:
#   kms → vpc → eks → s3 → rds → iam → waf → dns
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Repo      = var.github_repo
  }
}

# -----------------------------------------------------------------------------
# 1. KMS — encryption keys
# Created first because every other module references at least one key ARN.
# -----------------------------------------------------------------------------

module "kms" {
  source       = "./modules/kms"
  project_name = var.project_name
  tags         = local.common_tags
}

# -----------------------------------------------------------------------------
# 2. VPC — network
# Single AZ, 3 subnets by default.
# To go multi-AZ: add more CIDRs to the subnet list variables in tfvars.
# No code changes needed — module handles any list length.
# -----------------------------------------------------------------------------

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  aws_region   = var.aws_region
  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr

  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  isolated_subnet_cidrs = var.isolated_subnet_cidrs

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 3. EKS — cluster and managed node group
# Pure AWS resource creation. No namespaces, no addons via kubectl.
# -----------------------------------------------------------------------------

module "eks" {
  source       = "./modules/eks"
  project_name = var.project_name
  cluster_name = var.cluster_name

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  kms_key_arn     = module.kms.secrets_key_arn
  ebs_kms_key_arn = module.kms.ebs_key_arn

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 4. S3 — Loki log storage only
# Frontend is served from Nginx in Kubernetes — no S3 needed for it.
# -----------------------------------------------------------------------------

module "s3" {
  source         = "./modules/s3"
  project_name   = var.project_name
  s3_kms_key_arn = module.kms.s3_key_arn
  tags           = local.common_tags
}

# -----------------------------------------------------------------------------
# 5. RDS — managed MySQL
# One instance, two databases (qa_db and prod_db).
# Credentials auto-generated and stored in Secrets Manager.
# App reads creds via ESO → K8s Secret → env vars. No hardcoding ever.
# -----------------------------------------------------------------------------

module "rds" {
  source       = "./modules/rds"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id

  isolated_subnet_ids        = module.vpc.isolated_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id

  kms_key_arn         = module.kms.rds_key_arn
  secrets_kms_key_arn = module.kms.secrets_key_arn

  instance_class      = var.rds_instance_class
  deletion_protection = var.rds_deletion_protection

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 6. IAM — all IRSA roles
# Scoped to exactly what each component needs — nothing more.
# -----------------------------------------------------------------------------

module "iam" {
  source       = "./modules/iam"
  project_name = var.project_name
  cluster_name = var.cluster_name
  aws_region   = var.aws_region

  oidc_provider_arn        = module.eks.oidc_provider_arn
  cluster_oidc_issuer_url  = module.eks.cluster_oidc_issuer_url
  github_oidc_provider_arn = var.github_oidc_provider_arn

  github_org  = var.github_org
  github_repo = var.github_repo

  qa_secret_arn   = module.rds.qa_secret_arn
  prod_secret_arn = module.rds.prod_secret_arn

  secrets_kms_key_arn = module.kms.secrets_key_arn
  loki_bucket_arn     = module.s3.loki_bucket_arn
  s3_kms_key_arn      = module.kms.s3_key_arn

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 7. WAF — attached to ALB via ingress annotation in K8s layer
# -----------------------------------------------------------------------------

module "waf" {
  source       = "./modules/waf"
  project_name = var.project_name
  tags         = local.common_tags
}

# -----------------------------------------------------------------------------
# 8. DNS — ACM cert + Route53 records pointing to ALB
#
# alb_dns_name is empty on first apply (ALB doesn't exist yet).
# After kubernetes bootstrap creates the ALB:
#   kubectl get ingress -A  →  copy ADDRESS
#   fill alb_dns_name in terraform.tfvars
#   push → pipeline re-applies → DNS records created
# -----------------------------------------------------------------------------

module "dns" {
  source       = "./modules/dns"
  project_name = var.project_name
  domain_name  = var.domain_name
  alb_dns_name = var.alb_dns_name
  alb_zone_id  = var.alb_zone_id
  tags         = local.common_tags
}
