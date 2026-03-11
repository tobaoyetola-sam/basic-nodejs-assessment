###############################################################################
# terraform/bootstrap/main.tf
#
# ONE-TIME setup — run this BEFORE `terraform init` in the parent directory.
#
#   cd terraform/bootstrap
#   terraform init          # uses local state (checked-in to git is fine here)
#   terraform apply
#
# What it creates
#   • S3 bucket for Terraform state, with:
#       - versioning          (recover from accidental state corruption)
#       - AES-256 encryption  (state may contain secrets)
#       - public-access block (state must never be world-readable)
#       - lifecycle rule      (prune non-current versions after 90 days)
#   • S3 bucket policy that denies any non-TLS (HTTP) access
#
# Terraform 1.10+ uses a .tflock file written alongside the .tfstate object
# for locking — no DynamoDB table is required.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Bootstrap uses LOCAL state — it's a chicken-and-egg problem otherwise.
  # Commit terraform.tfstate from this directory so it is not lost.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "credpal-app"
      ManagedBy = "Terraform-Bootstrap"
    }
  }
}

# ── S3 bucket ────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Protect against accidental deletion of the bucket that holds all state
  lifecycle {
    prevent_destroy = true
  }
}

# Block every form of public access
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning — lets you restore a previous state if something goes wrong
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption with AWS-managed keys (SSE-S3 / AES-256)
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle: remove non-current versions older than 90 days to control cost
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Wait until versioning is enabled before setting the lifecycle rule
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Also remove delete markers left behind after version expiry
    expiration {
      expired_object_delete_marker = true
    }
  }
}

# Bucket policy — enforce TLS-only access and deny all HTTP requests
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Public access block must be in place before we can set a bucket policy
  depends_on = [aws_s3_bucket_public_access_block.tfstate]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "DenyNonEncryptedPuts"
        Effect = "Deny"
        Principal = "*"
        Action = "s3:PutObject"
        Resource = "${aws_s3_bucket.tfstate.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
        }
      }
    ]
  })
}
