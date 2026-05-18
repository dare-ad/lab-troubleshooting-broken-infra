#!/usr/bin/env bash
# Simulates out-of-band changes that produce drift against the Terraform state.
# Run this AFTER `terraform apply` of the clean baseline to reproduce Scenario 3.
#
# Drifts introduced:
#   1. S3 bucket versioning suspended via direct API call
#   2. DynamoDB table tagged out of band (ManagedBy, CostCenter)
#   3. New DynamoDB table created entirely outside Terraform (unmanaged)

set -euo pipefail

BUCKET_NAME="$(terraform output -raw bucket_name)"
TABLE_NAME="$(terraform output -raw table_name)"
TABLE_ARN="$(aws dynamodb describe-table --table-name "${TABLE_NAME}" --query 'Table.TableArn' --output text)"

echo "Applying drift 1: suspend bucket versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Suspended

echo "Applying drift 2: add out-of-band tags to DynamoDB table..."
aws dynamodb tag-resource \
  --resource-arn "${TABLE_ARN}" \
  --tags Key=ManagedBy,Value=compliance-bot Key=CostCenter,Value=eng-platform

echo "Applying drift 3: create unmanaged audit table..."
aws dynamodb create-table \
  --table-name "lab-sessions-audit-${RANDOM}" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=Lab,Value=troubleshooting-broken-infra Key=Scenario,Value=03-state Key=Environment,Value=lab \
  --query 'TableDescription.TableArn' \
  --output text

echo "Drift introduced. Run 'terraform plan' to see partial detection."
