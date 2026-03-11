variable "aws_region" {
  description = "AWS region where the state bucket will be created"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state S3 bucket"
  type        = string
  default     = "credpal-tfstate"
}
