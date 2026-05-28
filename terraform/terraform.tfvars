# -----------------------------------------------------------------------------
# YOUR VALUES — edit this file, nothing else.
# Committed to git. Contains no secrets — only identifiers and config.
# -----------------------------------------------------------------------------

aws_region   = "ap-south-1"
project_name = "uplatform"
cluster_name = "uplatform-cluster"
domain_name  = "jp2op-project.site"

github_org  = "Jp2op"
github_repo = "user-platform-v2"

# From: terraform output -chdir=bootstrap github_oidc_provider_arn
github_oidc_provider_arn = "arn:aws:iam::796197769514:oidc-provider/token.actions.githubusercontent.com"

# Network — single AZ (enough for a project)
# To go multi-AZ: add more CIDRs, e.g. ["10.0.1.0/24", "10.0.2.0/24"]
vpc_cidr              = "10.0.0.0/16"
public_subnet_cidrs   = ["10.0.1.0/24"]
private_subnet_cidrs  = ["10.0.10.0/24"]
isolated_subnet_cidrs = ["10.0.20.0/24"]

# EKS nodes — Spot for cost saving
node_instance_types = ["t3.medium", "t3a.medium"]
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 4

# RDS — free tier eligible
rds_instance_class      = "db.t3.micro"
rds_deletion_protection = true

# Fill after kubernetes bootstrap creates the ALB ingress:
# alb_dns_name = "k8s-XXXXX.ap-south-1.elb.amazonaws.com"
# alb_zone_id  = "ZP97RAFLXTNZK"
