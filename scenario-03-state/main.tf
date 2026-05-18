terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Lab      = "troubleshooting-broken-infra"
      Scenario = "03-state"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "config" {
  bucket        = "lab-config-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "lab-config"
    Environment = "lab"
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "sessions" {
  name         = "lab-sessions-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  tags = {
    Name        = "lab-sessions"
    Environment = "lab"
    ManagedBy   = "compliance-bot"
    CostCenter  = "eng-platform"
  }

  lifecycle {
    ignore_changes = [
      tags["ManagedBy"],
      tags["CostCenter"],
      tags_all["ManagedBy"],
      tags_all["CostCenter"],
    ]
  }
}

resource "aws_dynamodb_table" "sessions_audit" {
  name         = "lab-sessions-audit-15819"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = {
    Environment = "lab"
  }
}

output "audit_table_name" {
  value = aws_dynamodb_table.sessions_audit.name
}

output "bucket_name" {
  value = aws_s3_bucket.config.bucket
}

output "table_name" {
  value = aws_dynamodb_table.sessions.name
}
