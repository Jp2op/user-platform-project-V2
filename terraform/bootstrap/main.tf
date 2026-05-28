# -----------------------------------------------------------------------------
# BOOTSTRAP — run this once, manually, before anything else.
# Creates the foundation that every other Terraform run depends on:
#   1. S3 bucket for remote state
#   2. DynamoDB table for state locking
#   3. IAM role that GitHub Actions pipeline assumes via OIDC to run terraform
#
# After this runs you NEVER run terraform locally again.
# All infra changes go through the pipeline.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  # Bootstrap intentionally uses LOCAL state.
  # It's the only module that does — because there's no S3 bucket yet.
  # After applying, commit the generated terraform.tfstate to a secure location
  # or note down the outputs. You will not need to touch this again.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = "bootstrap"
    }
  }
}

# -----------------------------------------------------------------------------
# DATA — current AWS account and region (used to build ARNs)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# KMS KEY — encrypts the state bucket and DynamoDB table
# We create this here in bootstrap so state is encrypted from day one.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "terraform_state" {
  description             = "Encrypts Terraform state bucket and lock table"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-terraform-state-key"
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.project_name}-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

# -----------------------------------------------------------------------------
# S3 BUCKET — remote state storage
#
# Why these settings:
#   versioning         → every state file change is recoverable
#   encryption         → state contains sensitive values (db passwords etc)
#   block_public_acls  → state must never be public, ever
#   lifecycle rule     → keeps last 90 days of state versions, auto-deletes older
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  # Bucket names are globally unique. Using account ID avoids collisions.
  bucket = "${var.project_name}-tf-state-${data.aws_caller_identity.current.account_id}"

  # prevent_destroy stops `terraform destroy` from deleting your state.
  # If you genuinely need to delete this, remove the lifecycle block first.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project_name}-tf-state"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true # reduces KMS API call costs
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    # Empty filter = apply rule to all objects in the bucket
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Remove incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bucket policy — only the pipeline role can write state.
# Even if someone has AWS CLI configured locally, they cannot push state.
# This enforces the "pipeline only" rule at the AWS level, not just by convention.
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonPipelineWrites"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.terraform_state.arn}/*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = [
              # Pipeline role can write
              aws_iam_role.terraform_pipeline.arn,
              # Allow bootstrap itself to write (needed for initial setup)
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
            ]
          }
        }
      },
      {
        Sid    = "DenyHTTP"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  # Policy references the role — must wait for role creation
  depends_on = [aws_iam_role.terraform_pipeline]
}

# -----------------------------------------------------------------------------
# DYNAMODB TABLE — state locking
#
# Prevents two pipeline runs from modifying state simultaneously.
# If a pipeline run crashes mid-apply, the lock stays. You manually delete it:
#   aws dynamodb delete-item --table-name <name> --key '{"LockID":{"S":"<lock-id>"}}'
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_lock" {
  name         = "${var.project_name}-tf-lock"
  billing_mode = "PAY_PER_REQUEST" # no capacity planning needed, very low traffic
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.terraform_state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "${var.project_name}-tf-lock"
  }
}

# -----------------------------------------------------------------------------
# GITHUB OIDC PROVIDER
#
# Allows GitHub Actions to authenticate to AWS without static credentials.
# GitHub generates a short-lived JWT token per workflow run.
# AWS verifies the token against this OIDC provider and issues temporary creds.
#
# The thumbprint is GitHub's OIDC server certificate fingerprint.
# It rarely changes — but if it does, AWS will reject all GitHub Actions OIDC.
# Monitor: https://github.blog/changelog/
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # SHA-1 thumbprint of GitHub's OIDC TLS certificate
  # Current as of 2024 — verify at:
  # openssl s_client -connect token.actions.githubusercontent.com:443 2>/dev/null \
  #   | openssl x509 -fingerprint -noout -sha1
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# -----------------------------------------------------------------------------
# IAM ROLE — TerraformPipelineRole
#
# This is the role GitHub Actions assumes to run terraform plan/apply.
# Trust policy says: only GitHub Actions workflows from YOUR repo can assume it.
# The `sub` condition is the critical security control — without it, any
# GitHub repo could assume this role.
#
# We give it AdministratorAccess because Terraform needs to create any resource.
# In very large orgs you'd scope this down per resource type, but for a single
# project that's over-engineering.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "terraform_pipeline_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      # sub format: repo:<owner>/<repo>:ref:refs/heads/<branch>
      # Using StringLike with wildcard allows all branches and workflow triggers.
      # Tighten to a specific branch (e.g. :ref:refs/heads/main) if you want
      # to restrict apply to only the main branch.
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "terraform_pipeline" {
  name               = "${var.project_name}-terraform-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.terraform_pipeline_trust.json
  max_session_duration = 3600 # 1 hour — enough for any terraform apply

  tags = {
    Name = "${var.project_name}-terraform-pipeline-role"
  }
}

resource "aws_iam_role_policy_attachment" "terraform_pipeline_admin" {
  role       = aws_iam_role.terraform_pipeline.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# IAM ROLE — ReadOnly for developers
#
# Developers can run `terraform plan` locally to preview changes,
# but cannot apply. They can also inspect resources in the console.
# They CANNOT write to the state bucket (enforced by bucket policy above).
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "developer_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      # Replace with your actual developer IAM users/groups ARN
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "developer_readonly" {
  name               = "${var.project_name}-developer-readonly-role"
  assume_role_policy = data.aws_iam_policy_document.developer_trust.json

  tags = {
    Name = "${var.project_name}-developer-readonly"
  }
}

resource "aws_iam_role_policy_attachment" "developer_readonly" {
  role       = aws_iam_role.developer_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
