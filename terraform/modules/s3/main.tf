# -----------------------------------------------------------------------------
# S3 MODULE
#
# Single bucket: Loki log storage.
# Frontend is now served from Nginx in Kubernetes — no S3 needed for it.
#
# Loki writes all pod logs here for long-term retention.
# Lifecycle rule deletes logs older than 30 days (matches Loki retention config).
# Encrypted with KMS. No public access. Ever.
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

resource "aws_s3_bucket" "loki" {
  # Account ID suffix ensures global uniqueness without manual naming
  bucket = "${var.project_name}-loki-logs-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-loki-logs"
    Purpose = "loki-log-storage"
  })
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.s3_kms_key_arn
    }
    bucket_key_enabled = true  # reduces KMS API costs
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Delete log chunks older than 30 days
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    # Empty filter = apply to all objects
    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}