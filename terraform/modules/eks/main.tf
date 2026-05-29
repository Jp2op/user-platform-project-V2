# -----------------------------------------------------------------------------
# EKS MODULE
#
# Creates:
#   - EKS cluster (control plane managed by AWS)
#   - Managed node group in private subnets (t3.medium Spot for cost savings)
#   - OIDC provider for IRSA (lets pods assume IAM roles without static creds)
#   - Core addons: VPC CNI, CoreDNS, kube-proxy, EBS CSI driver
#   - Security groups: cluster SG and node SG with least-privilege rules
#
# Node choice — t3.medium Spot:
#   On-demand: ~$0.0416/hr   Spot: ~$0.013/hr   Savings: ~70%
#   Risk: Spot can be reclaimed. Mitigated by: 2 nodes across 2 AZs,
#   Kubernetes will reschedule pods within ~2 minutes of reclamation.
#   For production with real SLA, use on-demand or mixed (1 on-demand + spot).
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# IAM ROLE — EKS Cluster (control plane)
# The EKS control plane needs this role to manage AWS resources on your behalf
# -----------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# SECURITY GROUP — Cluster (control plane)
# EKS creates its own cluster SG automatically, but we add a custom one
# for fine-grained control over what can talk to the API server.
# -----------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-eks-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-eks-cluster-sg"
  })
}

# Allow nodes to talk to API server
resource "aws_security_group_rule" "cluster_ingress_nodes" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
  security_group_id        = aws_security_group.cluster.id
  description              = "Allow nodes to communicate with API server"
}

resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
  description       = "Allow all outbound from control plane"
}

# -----------------------------------------------------------------------------
# SECURITY GROUP — Nodes
# Nodes need to: talk to each other (pod-to-pod), talk to API server,
# receive traffic from ALB (via ALB's SG)
# -----------------------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.project_name}-eks-nodes-sg"
  description = "EKS worker nodes security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name                                              = "${var.project_name}-eks-nodes-sg"
    # This tag is required — EKS uses it to auto-attach the SG to nodes
    "kubernetes.io/cluster/${var.cluster_name}"       = "owned"
  })
}

# Nodes talk to each other freely (required for pod-to-pod and overlay network)
resource "aws_security_group_rule" "nodes_internal" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.nodes.id
  description       = "Allow nodes to communicate with each other"
}

# API server talks back to nodes (for webhooks, metrics, logs)
resource "aws_security_group_rule" "nodes_ingress_cluster" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.nodes.id
  description              = "Allow control plane to communicate with nodes"
}

resource "aws_security_group_rule" "nodes_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nodes.id
  description       = "Allow all outbound from nodes (goes via NAT)"
}

# -----------------------------------------------------------------------------
# EKS CLUSTER
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true   # API server reachable from within VPC
    endpoint_public_access  = true   # Also public so you can run kubectl from laptop
    # In a stricter setup set this to false and use a bastion/VPN.
    # For a solo project, public access with OIDC auth is acceptable.
    public_access_cidrs     = var.api_server_allowed_cidrs
  }

  # Encrypt Kubernetes secrets stored in etcd
  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  # Enable all control plane log types to CloudWatch
  # Useful for debugging auth issues, API server errors, scheduler decisions
  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  # Authentication mode: API_AND_CONFIG_MAP allows both EKS access entries
  # (our approach) and the legacy aws-auth ConfigMap. Best of both worlds.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

# -----------------------------------------------------------------------------
# IAM ROLE — Node Group
# EC2 instances (nodes) need this role to:
#   - Pull images from ECR
#   - Register with the cluster
#   - Send metrics/logs to CloudWatch
# -----------------------------------------------------------------------------

resource "aws_iam_role" "nodes" {
  name = "${var.project_name}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "nodes_worker_policy" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nodes_cni_policy" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nodes_ecr_policy" {
  role       = aws_iam_role.nodes.name
  # ReadOnly — nodes only pull images, never push
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EBS CSI driver needs this to manage EBS volumes
resource "aws_iam_role_policy_attachment" "nodes_ebs_csi" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# MANAGED NODE GROUP
#
# Using SPOT instances for ~70% cost savings.
# Two nodes minimum — if one gets reclaimed, workloads shift to the other.
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.private_subnet_ids  # nodes go in PRIVATE subnets

  # Spot capacity type for cost savings
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Rolling update strategy: replace one node at a time
  update_config {
    max_unavailable = 1
  }

  # IMDSv2 enforced at node group level — no custom launch template needed.
  # EKS manages the AMI selection automatically (always uses latest EKS-optimized AMI).
  node_repair_config {
    enabled = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-nodes"
  })

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker_policy,
    aws_iam_role_policy_attachment.nodes_cni_policy,
    aws_iam_role_policy_attachment.nodes_ecr_policy,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# OIDC PROVIDER — enables IRSA (IAM Roles for Service Accounts)
#
# This is what lets a Kubernetes service account assume an AWS IAM role.
# Without this, pods would need static AWS credentials in env vars or secrets.
# With this, a pod annotated with a service account gets temporary credentials
# automatically, scoped to exactly the permissions that role has.
# -----------------------------------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name = "${var.project_name}-eks-oidc"
  })
}

# -----------------------------------------------------------------------------
# EKS ADDONS
#
# Managed addons are updated by AWS. We pin versions for stability.
# Check latest versions: aws eks describe-addon-versions --addon-name <name>
# -----------------------------------------------------------------------------

# VPC CNI — manages pod networking within the VPC
# Each pod gets a real VPC IP address from the node's ENI
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# CoreDNS — internal DNS for service discovery
resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.main]
}

# kube-proxy — network rules on each node for Service load balancing
resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# EBS CSI Driver — allows PersistentVolumeClaims to provision EBS volumes
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"

  # EBS CSI needs an IRSA role to authenticate to AWS for EBS operations
  # We use the node role ARN which already has AmazonEBSCSIDriverPolicy attached
  service_account_role_arn = aws_iam_role.nodes.arn

  tags = var.tags

  depends_on = [aws_eks_node_group.main]
}

# EKS Pod Identity addon — newer alternative to IRSA, we enable both
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.main]
}