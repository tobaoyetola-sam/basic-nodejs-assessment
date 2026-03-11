terraform {
  # S3 native locking (use_lockfile) requires Terraform >= 1.10
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state with S3-native lock file (no DynamoDB needed from Terraform 1.10+)
  # Run `terraform/bootstrap/` first to create the bucket before using this backend.
  backend "s3" {
    bucket       = "credpal-tfstate"
    key          = "credpal-app/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true

    # S3-native locking: Terraform writes a <key>.tflock object alongside
    # the state file instead of relying on a DynamoDB table.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "credpal-app"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ── VPC ──────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  availability_zones  = var.availability_zones
  public_subnet_cidrs = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ── Compute (ECS Fargate) ─────────────────────────────────────────────────
module "compute" {
  source = "./modules/compute"

  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  app_sg_id          = module.vpc.app_sg_id
  alb_target_group_arn = module.loadbalancer.target_group_arn

  app_image        = var.app_image
  app_version      = var.app_version
  app_port         = var.app_port
  desired_count    = var.desired_count
  cpu              = var.task_cpu
  memory           = var.task_memory

  db_secret_arn    = aws_secretsmanager_secret.db_credentials.arn
}

# ── Load Balancer + ACM certificate ──────────────────────────────────────
module "loadbalancer" {
  source = "./modules/loadbalancer"

  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.vpc.alb_sg_id
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn
  app_port          = var.app_port
}

# ── Secrets Manager – DB credentials ─────────────────────────────────────
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "/${var.environment}/credpal-app/db-credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = var.db_host
    port     = "5432"
    dbname   = var.db_name
  })
}

# ── ACM TLS certificate (DNS validation via Route 53) ────────────────────
resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.app.zone_id
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ── Route 53 – A record pointing to ALB ──────────────────────────────────
data "aws_route53_zone" "app" {
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.app.zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = module.loadbalancer.alb_dns_name
    zone_id                = module.loadbalancer.alb_zone_id
    evaluate_target_health = true
  }
}
