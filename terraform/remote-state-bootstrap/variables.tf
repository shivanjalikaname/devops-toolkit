variable "bucket_name" {
  description = "Globally unique name for the state bucket, e.g. acme-tfstate-prod-eu-west-1."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars of lowercase letters, digits, dots and hyphens."
  }
}

variable "create_lock_table" {
  description = <<-EOT
    Create a DynamoDB table for state locking. Terraform >= 1.10 can lock with
    S3 alone (use_lockfile = true); keep this on while any pipeline still runs
    an older Terraform or OpenTofu version.
  EOT
  type        = bool
  default     = true
}

variable "lock_table_name" {
  description = "DynamoDB lock table name. Defaults to <bucket_name>-lock."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for bucket encryption. null uses SSE-S3 (AES256)."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep old state versions before expiring them. 0 keeps them forever."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 0
    error_message = "noncurrent_version_retention_days cannot be negative."
  }
}

variable "allowed_principal_arns" {
  description = "If set, only these IAM principals (plus the account root) may read or write state objects."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
