output "bucket_name" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket, for IAM policies on CI roles."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB lock table name, or null when create_lock_table = false."
  value       = one(aws_dynamodb_table.lock[*].name)
}

output "lock_table_arn" {
  description = "DynamoDB lock table ARN, or null when create_lock_table = false."
  value       = one(aws_dynamodb_table.lock[*].arn)
}

output "backend_config" {
  description = "Ready-to-paste backend block. Change `key` per stack."
  value = templatefile("${path.module}/backend.tf.tftpl", {
    bucket     = aws_s3_bucket.state.id
    region     = data.aws_region.current.region
    lock_table = one(aws_dynamodb_table.lock[*].name)
    kms_key    = var.kms_key_arn
  })
}
