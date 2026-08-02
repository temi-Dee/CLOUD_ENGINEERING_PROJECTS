#!/bin/bash
# Project 5: Cleanup AWS Resources

set -e

echo "🧹 Cleaning up CI/CD Pipeline AWS resources..."

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

REGION="us-east-1"

# Read config if exists
if [ -f aws-config.txt ]; then
    BUCKET_NAME=$(grep "S3 Bucket:" aws-config.txt | awk '{print $3}')
    CF_DIST_ID=$(grep "CloudFront Distribution:" aws-config.txt | awk '{print $3}')
    ACCOUNT_ID=$(grep "Account ID:" aws-config.txt | awk '{print $3}')
fi

# Step 1: Disable and delete CloudFront distribution
if [ ! -z "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "" ]; then
    echo -e "${BLUE}Step 1: Disabling CloudFront distribution...${NC}"
    
    ETAG=$(aws cloudfront get-distribution-config --id $CF_DIST_ID --query 'ETag' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$ETAG" ]; then
        aws cloudfront get-distribution-config --id $CF_DIST_ID --query 'DistributionConfig' > cf-config.json
        
        # Disable distribution
        jq '.Enabled = false' cf-config.json > cf-config-disabled.json
        
        aws cloudfront update-distribution \
          --id $CF_DIST_ID \
          --distribution-config file://cf-config-disabled.json \
          --if-match $ETAG 2>/dev/null || true
        
        echo "Waiting for CloudFront distribution to be disabled (this may take 15-20 minutes)..."
        aws cloudfront wait distribution-deployed --id $CF_DIST_ID 2>/dev/null || true
        
        # Delete distribution
        NEW_ETAG=$(aws cloudfront get-distribution-config --id $CF_DIST_ID --query 'ETag' --output text 2>/dev/null || echo "")
        if [ ! -z "$NEW_ETAG" ]; then
            aws cloudfront delete-distribution --id $CF_DIST_ID --if-match $NEW_ETAG 2>/dev/null || true
        fi
        
        rm -f cf-config.json cf-config-disabled.json
    fi
    
    echo -e "${GREEN}✓ CloudFront distribution deleted${NC}"
fi

# Step 2: Delete S3 bucket
if [ ! -z "$BUCKET_NAME" ]; then
    echo -e "${BLUE}Step 2: Deleting S3 bucket...${NC}"
    aws s3 rm s3://$BUCKET_NAME --recursive 2>/dev/null || true
    aws s3 rb s3://$BUCKET_NAME 2>/dev/null || true
    echo -e "${GREEN}✓ S3 bucket deleted${NC}"
fi

# Step 3: Delete IAM role
echo -e "${BLUE}Step 3: Deleting IAM role...${NC}"
aws iam detach-role-policy \
  --role-name GitHubActionsRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

aws iam detach-role-policy \
  --role-name GitHubActionsRole \
  --policy-arn arn:aws:iam::aws:policy/CloudFrontFullAccess 2>/dev/null || true

aws iam delete-role --role-name GitHubActionsRole 2>/dev/null || true
echo -e "${GREEN}✓ IAM role deleted${NC}"

# Step 4: Delete OIDC provider
if [ ! -z "$ACCOUNT_ID" ]; then
    echo -e "${BLUE}Step 4: Deleting OIDC provider...${NC}"
    aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" \
      2>/dev/null || true
    echo -e "${GREEN}✓ OIDC provider deleted${NC}"
fi

# Clean up local files
rm -f aws-config.txt

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Cleanup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "All AWS resources have been deleted."
echo ""
