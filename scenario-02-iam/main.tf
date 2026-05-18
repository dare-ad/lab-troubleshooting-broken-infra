terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
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
      Scenario = "02-iam"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

# Heartbeat bucket the Lambda should write to
resource "aws_s3_bucket" "heartbeat" {
  bucket        = "lab-heartbeat-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "heartbeat" {
  bucket                  = aws_s3_bucket.heartbeat.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Inline the Lambda source so you don't need a separate file
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/heartbeat.zip"

  source {
    filename = "index.py"
    content  = <<-PYTHON
      import boto3
      import json
      import os
      from datetime import datetime, timezone

      s3 = boto3.client("s3")

      def handler(event, context):
          bucket = os.environ["BUCKET_NAME"]
          key = f"heartbeat/{datetime.now(timezone.utc).isoformat()}.json"
          body = json.dumps({
              "ts": datetime.now(timezone.utc).isoformat(),
              "request_id": context.aws_request_id,
          })
          s3.put_object(Bucket=bucket, Key=key, Body=body)
          return {"status": "ok", "key": key}
    PYTHON
  }
}

# Trust policy: who can assume this role
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "lab-heartbeat-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Identity policy: what the role is allowed to do
data "aws_iam_policy_document" "lambda_perms" {
  statement {
    sid       = "WriteHeartbeat"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.heartbeat.arn}/*"]
  }

  statement {
    sid       = "LogsBasic"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "lab-heartbeat-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_perms.json
}

resource "aws_lambda_function" "heartbeat" {
  function_name    = "lab-heartbeat"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.heartbeat.bucket
    }
  }
}

# Schedule: every 5 minutes
resource "aws_cloudwatch_event_rule" "every_5min" {
  name                = "lab-heartbeat-every-5min"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "heartbeat" {
  rule      = aws_cloudwatch_event_rule.every_5min.name
  target_id = "heartbeat-lambda"
  arn       = aws_lambda_function.heartbeat.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_5min.arn
}

output "bucket_name" {
  value = aws_s3_bucket.heartbeat.bucket
}

output "function_name" {
  value = aws_lambda_function.heartbeat.function_name
}

output "role_name" {
  value = aws_iam_role.lambda.name
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.every_5min.name
}
