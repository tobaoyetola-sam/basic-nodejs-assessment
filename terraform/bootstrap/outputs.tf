output "state_bucket_name" {
  description = "Name of the S3 bucket — paste into the parent backend config"
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket"
  value       = aws_s3_bucket.tfstate.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket"
  value       = aws_s3_bucket.tfstate.region
}
