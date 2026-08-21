#!/bin/bash
set -e

PRIMARY_REGION="us-east-1"
SECONDARY_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws dynamodb create-table \
  --table-name global-app-data \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region $PRIMARY_REGION

aws dynamodb wait table-exists --table-name global-app-data --region $PRIMARY_REGION

aws dynamodb update-table \
  --table-name global-app-data \
  --replica-updates "[{\"Create\":{\"RegionName\":\"$SECONDARY_REGION\"}}]" \
  --region $PRIMARY_REGION
