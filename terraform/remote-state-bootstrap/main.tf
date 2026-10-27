# remote-state-bootstrap - S3 bucket (and optional DynamoDB lock table) for Terraform state.
#
# Chicken-and-egg module: apply it once per account with local state, then point
# every other stack at the bucket. The bucket is versioned, encrypted, private,
# TLS-only and protected with prevent_destroy, because losing state is far worse
# than a failed `terraform destroy`.
#
# Usage:
#   module "tfstate" {
#     source      = "github.com/shivanjalikaname/devops-toolkit//terraform/remote-state-bootstrap"
#     bucket_name = "acme-tfstate-prod-eu-west-1"
#     tags        = { owner = "platform", cost-center = "infra" }
#   }
#
#   terraform init && terraform apply
#   terraform output -raw backend_config > ../other-stack/backend.tf
#
# Examples:
#   # Terraform >= 1.10 everywhere: skip DynamoDB, lock with S3 lockfiles
#   create_lock_table = false
#
#   # Restrict state access to the CI role and the break-glass admin role
#   allowed_principal_arns = ["arn:aws:iam::123456789012:role/ci-terraform",
#                             "arn:aws:iam::123456789012:role/admin"]

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  lock_table_name = coalesce(var.lock_table_name, "${var.bucket_name}-lock")
  account_root    = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

resource "aws_s3_bucket" "state" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = var.noncurrent_version_retention_days > 0 ? "Enabled" : "Disabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = max(var.noncurrent_version_retention_days, 1)
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Versioning must be on before lifecycle rules on noncurrent versions make sense.
  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = length(var.allowed_principal_arns) > 0 ? [1] : []

    content {
      sid       = "DenyStateAccessOutsideAllowList"
      effect    = "Deny"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.state.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      # The account root stays in the list so nobody can lock the account out of its own state.
      condition {
        test     = "ArnNotLike"
        variable = "aws:PrincipalArn"
        values   = concat(var.allowed_principal_arns, [local.account_root])
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_dynamodb_table" "lock" {
  count = var.create_lock_table ? 1 : 0

  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  tags         = var.tags

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = true
}
