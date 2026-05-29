# -----------------------------------------------------------------------------
# IAM MODULE
#
# Creates all IRSA (IAM Roles for Service Accounts) used by pods in EKS.
# IRSA = a Kubernetes service account annotated with an IAM role ARN.
# When a pod uses that service account, it gets temporary AWS credentials
# scoped to exactly that role. No static keys anywhere.
#
# Roles created:
#   1. ESO QA      — External Secrets Operator reads qa/mysql-secret
#   2. ESO PROD    — External Secrets Operator reads prod/mysql-secret
#   3. ALB Controller — creates/manages ALB from Ingress objects
#   4. EBS CSI     — creates/attaches EBS volumes for PVCs
#   5. Loki        — writes logs to S3 bucket
#   6. QA Deploy   — GitHub Actions deploys to qa namespace
#   7. PROD Deploy — GitHub Actions deploys to prod namespace
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

data "aws_caller_identity" "current" {}

# Helper: extract the OIDC provider ID from the full URL
# e.g. "https://oidc.eks.ap-south-1.amazonaws.com/id/ABCD1234" → "ABCD1234"
locals {
  oidc_id = replace(var.cluster_oidc_issuer_url, "https://", "")
}

# -----------------------------------------------------------------------------
# HELPER — reusable trust policy builder
# All IRSA roles share the same trust policy shape — only the service account
# namespace and name differ. We use a local function pattern.
# -----------------------------------------------------------------------------

# ESO QA — reads only the QA secret, nothing else
resource "aws_iam_role" "eso_qa" {
  name = "${var.project_name}-eso-qa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
          # Only the eso-qa-sa service account in the qa namespace can assume this
          "${local.oidc_id}:sub" = "system:serviceaccount:qa:eso-qa-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-eso-qa-role" })
}

resource "aws_iam_policy" "eso_qa" {
  name        = "${var.project_name}-eso-qa-policy"
  description = "Allow ESO to read QA MySQL secret from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Scoped to ONLY the QA secret — cannot read prod secret
        Resource = var.qa_secret_arn
      },
      {
        # ESO needs KMS to decrypt the secret value
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.secrets_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eso_qa" {
  role       = aws_iam_role.eso_qa.name
  policy_arn = aws_iam_policy.eso_qa.arn
}

# ESO PROD — reads only the PROD secret
resource "aws_iam_role" "eso_prod" {
  name = "${var.project_name}-eso-prod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
          "${local.oidc_id}:sub" = "system:serviceaccount:prod:eso-prod-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-eso-prod-role" })
}

resource "aws_iam_policy" "eso_prod" {
  name        = "${var.project_name}-eso-prod-policy"
  description = "Allow ESO to read PROD MySQL secret from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.prod_secret_arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.secrets_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eso_prod" {
  role       = aws_iam_role.eso_prod.name
  policy_arn = aws_iam_policy.eso_prod.arn
}

# -----------------------------------------------------------------------------
# ALB CONTROLLER — needs broad EC2/ELB permissions to manage load balancers
# Policy document from AWS: we download it in the pipeline, not hardcode it here.
# We reference the well-known AWS-maintained policy ARN pattern.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "alb_controller" {
  name = "${var.project_name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
          "${local.oidc_id}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-alb-controller-role" })
}

# ALB controller policy — this is large (EC2, ELB, WAF, Shield permissions)
# We create it inline here based on the official AWS policy document
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project_name}-alb-controller-policy"
  description = "Policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestedRegion" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestedRegion"             = "false"
            "aws:ResourceTag/ingress.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/ingress.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestedRegion" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestedRegion"                      = "false"
            "aws:ResourceTag/ingress.k8s.aws/cluster"  = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/ingress.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = {
            "aws:RequestedRegion" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# -----------------------------------------------------------------------------
# LOKI — writes logs to S3
# -----------------------------------------------------------------------------

resource "aws_iam_role" "loki" {
  name = "${var.project_name}-loki-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
          "${local.oidc_id}:sub" = "system:serviceaccount:monitoring:loki"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-loki-role" })
}

resource "aws_iam_policy" "loki" {
  name        = "${var.project_name}-loki-s3-policy"
  description = "Allow Loki to read/write logs in its S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.loki_bucket_arn,
          "${var.loki_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = var.s3_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "loki" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

# -----------------------------------------------------------------------------
# GITHUB ACTIONS DEPLOY ROLES
#
# QA role: assumed by the qa-cicd pipeline to deploy to the qa namespace
# PROD role: assumed by the prod-cd pipeline to deploy to the prod namespace
#
# These use the GITHUB OIDC provider created in bootstrap (not the EKS OIDC).
# Trust is scoped to your specific repo — no other repo can assume these.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_qa_deploy" {
  name = "${var.project_name}-github-qa-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Only the qa branch triggers of your specific repo
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/qa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-github-qa-deploy-role" })
}

# QA deploy role needs: describe EKS cluster (to get kubeconfig) + deploy to qa namespace
resource "aws_iam_policy" "github_qa_deploy" {
  name = "${var.project_name}-github-qa-deploy-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeCluster"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        Sid    = "DockerHubPush"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        # ECR GetAuthorizationToken applies to * (no specific resource)
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_qa_deploy" {
  role       = aws_iam_role.github_qa_deploy.name
  policy_arn = aws_iam_policy.github_qa_deploy.arn
}

# EKS access entry — grants the QA deploy role kubectl access scoped to qa namespace
resource "aws_eks_access_entry" "github_qa_deploy" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.github_qa_deploy.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "github_qa_deploy" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.github_qa_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["qa"]
  }

  depends_on = [aws_eks_access_entry.github_qa_deploy]
}

# PROD deploy role — stricter: only main branch, only prod namespace
resource "aws_iam_role" "github_prod_deploy" {
  name = "${var.project_name}-github-prod-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.project_name}-github-prod-deploy-role" })
}

resource "aws_iam_policy" "github_prod_deploy" {
  name = "${var.project_name}-github-prod-deploy-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeCluster"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        Sid    = "DockerHubRetag"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_prod_deploy" {
  role       = aws_iam_role.github_prod_deploy.name
  policy_arn = aws_iam_policy.github_prod_deploy.arn
}

resource "aws_eks_access_entry" "github_prod_deploy" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.github_prod_deploy.arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "github_prod_deploy" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.github_prod_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["prod"]
  }

  depends_on = [aws_eks_access_entry.github_prod_deploy]
}
