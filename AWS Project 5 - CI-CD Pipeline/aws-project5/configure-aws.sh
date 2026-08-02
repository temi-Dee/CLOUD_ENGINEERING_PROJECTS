#!/bin/bash
# Project 5: Configure AWS Resources for CI/CD Pipeline

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

REGION="us-east-1"
GITHUB_USERNAME="${1:-YOUR_GITHUB_USERNAME}"
REPO_NAME="${2:-my-app}"

if [ "$GITHUB_USERNAME" == "YOUR_GITHUB_USERNAME" ]; then
    echo -e "${YELLOW}Usage: ./configure-aws.sh <github-username> <repo-name>${NC}"
    echo -e "${YELLOW}Example: ./configure-aws.sh johndoe my-awesome-app${NC}"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Step 1: Create OIDC Provider
echo -e "${BLUE}Step 1: Creating OIDC Provider for GitHub Actions...${NC}"
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  2>/dev/null || echo "OIDC provider already exists"
echo -e "${GREEN}✓ OIDC Provider configured${NC}"

# Step 2: Create IAM Role (policies added in Step 6 once bucket/distribution are known)
echo -e "${BLUE}Step 2: Creating IAM Role for GitHub Actions...${NC}"
cat > github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_USERNAME}/${REPO_NAME}:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name GitHubActionsRole \
  --assume-role-policy-document file://github-trust-policy.json \
  --description "Role for GitHub Actions CI/CD" \
  2>/dev/null || echo "Role already exists"
echo -e "${GREEN}✓ IAM Role created${NC}"

# Step 3: Create private S3 Bucket
echo -e "${BLUE}Step 3: Creating private S3 Bucket...${NC}"
BUCKET_NAME="my-app-cicd-${ACCOUNT_ID}-$(date +%s)"
aws s3 mb "s3://$BUCKET_NAME" --region "$REGION"

# Keep all public access blocked — objects served exclusively via CloudFront
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Versioning allows rollback to a previous deployment
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo -e "${GREEN}✓ Private S3 Bucket created: $BUCKET_NAME${NC}"

# Step 4: Create CloudFront Origin Access Control + Distribution
echo -e "${BLUE}Step 4: Creating CloudFront distribution with OAC...${NC}"

OAC_ID=$(aws cloudfront create-origin-access-control \
  --origin-access-control-config \
    "Name=cicd-oac-${BUCKET_NAME},OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4" \
  --query 'OriginAccessControl.Id' --output text)

CF_DIST_ID=$(aws cloudfront create-distribution \
  --distribution-config "{
    \"CallerReference\": \"cicd-$(date +%s)\",
    \"Comment\": \"CloudFront distribution for CI/CD app ${REPO_NAME}\",
    \"Enabled\": true,
    \"Origins\": {
      \"Quantity\": 1,
      \"Items\": [{
        \"Id\": \"S3-${BUCKET_NAME}\",
        \"DomainName\": \"${BUCKET_NAME}.s3.${REGION}.amazonaws.com\",
        \"S3OriginConfig\": {\"OriginAccessIdentity\": \"\"},
        \"OriginAccessControlId\": \"${OAC_ID}\"
      }]
    },
    \"DefaultCacheBehavior\": {
      \"TargetOriginId\": \"S3-${BUCKET_NAME}\",
      \"ViewerProtocolPolicy\": \"redirect-to-https\",
      \"AllowedMethods\": {
        \"Quantity\": 2,
        \"Items\": [\"GET\", \"HEAD\"],
        \"CachedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"]}
      },
      \"ForwardedValues\": {\"QueryString\": false, \"Cookies\": {\"Forward\": \"none\"}},
      \"MinTTL\": 0,
      \"DefaultTTL\": 86400,
      \"MaxTTL\": 31536000,
      \"Compress\": true
    },
    \"DefaultRootObject\": \"index.html\",
    \"CustomErrorResponses\": {
      \"Quantity\": 1,
      \"Items\": [{
        \"ErrorCode\": 404,
        \"ResponseCode\": \"200\",
        \"ResponsePagePath\": \"/index.html\",
        \"ErrorCachingMinTTL\": 300
      }]
    }
  }" \
  --query 'Distribution.Id' --output text)

CF_DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_DIST_ID}"

CF_DOMAIN=$(aws cloudfront get-distribution \
  --id "$CF_DIST_ID" \
  --query 'Distribution.DomainName' --output text)

echo -e "${GREEN}✓ CloudFront distribution created: $CF_DIST_ID${NC}"

# Step 5: Bucket policy — allow only this CloudFront distribution to read objects
cat > bucket-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipal",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "${CF_DIST_ARN}"
      }
    }
  }]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy file://bucket-policy.json
echo -e "${GREEN}✓ Bucket policy applied (CloudFront-only access)${NC}"

# Step 6: Least-privilege inline policy scoped to this bucket and distribution only
cat > github-actions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ObjectAccess",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    },
    {
      "Sid": "S3ListAccess",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "CloudFrontInvalidate",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "${CF_DIST_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActionsRole \
  --policy-name GitHubActionsCICD \
  --policy-document file://github-actions-policy.json
echo -e "${GREEN}✓ Least-privilege inline policy attached to GitHubActionsRole${NC}"

# Save configuration
cat > aws-config.txt << EOF
AWS CI/CD Configuration
=======================

Account ID: $ACCOUNT_ID
Region: $REGION
GitHub Repo: $GITHUB_USERNAME/$REPO_NAME

Resources Created:
------------------
OIDC Provider: token.actions.githubusercontent.com
IAM Role: GitHubActionsRole (inline least-privilege policy)
S3 Bucket: $BUCKET_NAME (private — served only via CloudFront)
CloudFront OAC: $OAC_ID
CloudFront Distribution: $CF_DIST_ID
CloudFront Domain: https://$CF_DOMAIN

GitHub Secrets to Configure:
-----------------------------
AWS_ACCOUNT_ID: $ACCOUNT_ID
S3_BUCKET: $BUCKET_NAME
CF_DISTRIBUTION_ID: $CF_DIST_ID

Commands to Set GitHub Secrets:
--------------------------------
gh secret set AWS_ACCOUNT_ID --body "$ACCOUNT_ID"
gh secret set S3_BUCKET --body "$BUCKET_NAME"
gh secret set CF_DISTRIBUTION_ID --body "$CF_DIST_ID"

Test Deployment:
----------------
1. Push code to GitHub main branch
2. Monitor workflow: gh run watch
3. Visit: https://$CF_DOMAIN

Cleanup:
--------
To delete all resources, run: ./cleanup-pipeline.sh $BUCKET_NAME $CF_DIST_ID $OAC_ID
EOF

rm -f github-trust-policy.json bucket-policy.json github-actions-policy.json

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ AWS Configuration Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "S3 Bucket:       ${BLUE}$BUCKET_NAME${NC} (private)"
echo -e "CloudFront URL:  ${BLUE}https://$CF_DOMAIN${NC}"
echo -e "Distribution ID: ${BLUE}$CF_DIST_ID${NC}"
echo ""
echo "Next: configure GitHub secrets (see aws-config.txt)"
echo ""
