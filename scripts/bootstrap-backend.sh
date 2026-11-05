#!/usr/bin/env bash
# One-time bootstrap of the Terraform remote state bucket and DynamoDB lock table.
set -euo pipefail

BUCKET="${1:?usage: bootstrap-backend.sh BUCKET TABLE REGION}"
TABLE="${2:?usage: bootstrap-backend.sh BUCKET TABLE REGION}"
REGION="${3:?usage: bootstrap-backend.sh BUCKET TABLE REGION}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Bootstrapping state for account ${ACCOUNT_ID} in ${REGION}"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Creating state bucket ${BUCKET}"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
else
  echo "State bucket ${BUCKET} already exists"
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,BlockPublicPolicy=true,IgnorePublicAcls=true,RestrictPublicBuckets=true

if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  echo "Creating lock table ${TABLE}"
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
else
  echo "Lock table ${TABLE} already exists"
fi

echo "Bootstrap complete."
echo "Next: cd terraform && make plan"
