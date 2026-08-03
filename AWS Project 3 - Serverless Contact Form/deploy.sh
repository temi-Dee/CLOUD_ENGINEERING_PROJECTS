#!/bin/bash
# Project 3: Serverless Contact Form Deployment

set -e

echo "🚀 Deploying Serverless Contact Form..."

# Variables
SENDER_EMAIL="your-email@example.com"  # CHANGE THIS
RECIPIENT_EMAIL="your-email@example.com"  # CHANGE THIS
REGION="us-east-1"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if email is configured
if [ "$SENDER_EMAIL" == "your-email@example.com" ]; then
    echo -e "${YELLOW}⚠️  Please edit deploy.sh and set SENDER_EMAIL and RECIPIENT_EMAIL${NC}"
    exit 1
fi

# Step 1: Verify email in SES
echo -e "${BLUE}Step 1: Verifying email in SES...${NC}"
aws ses verify-email-identity --email-address $SENDER_EMAIL --region $REGION
echo -e "${YELLOW}⚠️  Check your email ($SENDER_EMAIL) and click the verification link!${NC}"
echo "Press Enter after verifying your email..."
read

# Step 2: Create IAM Role for Lambda
echo -e "${BLUE}Step 2: Creating IAM Role...${NC}"
cat > lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name ContactFormLambdaRole \
  --assume-role-policy-document file://lambda-trust-policy.json \
  2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
  --role-name ContactFormLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  2>/dev/null || true

cat > ses-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ses:SendEmail", "ses:SendRawEmail"],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name ContactFormLambdaRole \
  --policy-name SESSendPolicy \
  --policy-document file://ses-policy.json

ROLE_ARN=$(aws iam get-role --role-name ContactFormLambdaRole --query 'Role.Arn' --output text)
echo -e "${GREEN}✓ IAM Role created${NC}"

# Wait for role to propagate
echo "Waiting for IAM role to propagate..."
sleep 10

# Step 3: Package Lambda function
echo -e "${BLUE}Step 3: Packaging Lambda function...${NC}"
cd lambda
npm install --production
zip -r ../function.zip .
cd ..
echo -e "${GREEN}✓ Lambda package created${NC}"

# Step 4: Create Lambda function
echo -e "${BLUE}Step 4: Creating Lambda function...${NC}"
aws lambda create-function \
  --function-name ContactFormHandler \
  --runtime nodejs18.x \
  --role $ROLE_ARN \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --timeout 30 \
  --memory-size 256 \
  --environment Variables="{SENDER_EMAIL=$SENDER_EMAIL,RECIPIENT_EMAIL=$RECIPIENT_EMAIL}" \
  --region $REGION \
  2>/dev/null || aws lambda update-function-code \
  --function-name ContactFormHandler \
  --zip-file fileb://function.zip \
  --region $REGION

echo -e "${GREEN}✓ Lambda function created${NC}"

# Step 5: Create API Gateway
echo -e "${BLUE}Step 5: Creating API Gateway...${NC}"
API_ID=$(aws apigateway create-rest-api \
  --name ContactFormAPI \
  --description "API for serverless contact form" \
  --region $REGION \
  --query 'id' \
  --output text 2>/dev/null || aws apigateway get-rest-apis \
  --query "items[?name=='ContactFormAPI'].id" \
  --output text \
  --region $REGION)

ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID \
  --region $REGION \
  --query 'items[0].id' \
  --output text)

# Create /contact resource
RESOURCE_ID=$(aws apigateway create-resource \
  --rest-api-id $API_ID \
  --parent-id $ROOT_ID \
  --path-part contact \
  --region $REGION \
  --query 'id' \
  --output text 2>/dev/null || aws apigateway get-resources \
  --rest-api-id $API_ID \
  --region $REGION \
  --query "items[?pathPart=='contact'].id" \
  --output text)

# Create POST method
aws apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --authorization-type NONE \
  --region $REGION 2>/dev/null || true

# Create OPTIONS method for CORS
aws apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --authorization-type NONE \
  --region $REGION 2>/dev/null || true

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function --function-name ContactFormHandler --region $REGION --query 'Configuration.FunctionArn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Set up Lambda integration
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --region $REGION 2>/dev/null || true

# Set up OPTIONS integration for CORS
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --type MOCK \
  --request-templates '{"application/json": "{\"statusCode\": 200}"}' \
  --region $REGION 2>/dev/null || true

aws apigateway put-method-response \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Headers": true, "method.response.header.Access-Control-Allow-Methods": true, "method.response.header.Access-Control-Allow-Origin": true}' \
  --region $REGION 2>/dev/null || true

aws apigateway put-integration-response \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'\''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'\''", "method.response.header.Access-Control-Allow-Methods": "'\''POST,OPTIONS'\''", "method.response.header.Access-Control-Allow-Origin": "'\''*'\''"}'  \
  --region $REGION 2>/dev/null || true

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission \
  --function-name ContactFormHandler \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/contact" \
  --region $REGION 2>/dev/null || true

# Deploy API
aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod \
  --region $REGION

API_ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/contact"

echo -e "${GREEN}✓ API Gateway created${NC}"

# Step 6: Update HTML with API endpoint
echo -e "${BLUE}Step 6: Updating HTML file...${NC}"
sed -i.bak "s|YOUR_API_GATEWAY_ENDPOINT_HERE|$API_ENDPOINT|g" frontend/contact.html
echo -e "${GREEN}✓ HTML updated${NC}"

# Save deployment info
cat > deployment-info.txt << EOF
API Gateway ID: $API_ID
API Endpoint: $API_ENDPOINT
Lambda Function: ContactFormHandler
Sender Email: $SENDER_EMAIL
Recipient Email: $RECIPIENT_EMAIL
Region: $REGION

Test the form:
1. Open frontend/contact.html in a browser
2. Fill out the form and submit
3. Check $RECIPIENT_EMAIL for the email

Test via curl:
curl -X POST $API_ENDPOINT \\
  -H "Content-Type: application/json" \\
  -d '{"name":"Test User","email":"test@example.com","message":"Test message"}'
EOF

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "API Endpoint: ${BLUE}$API_ENDPOINT${NC}"
echo -e "Contact Form: ${BLUE}frontend/contact.html${NC}"
echo ""
echo "📧 Test the form by opening frontend/contact.html in your browser"
echo ""
echo "Deployment info saved to deployment-info.txt"
