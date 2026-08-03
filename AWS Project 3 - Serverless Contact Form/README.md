# Project 3: Serverless Contact Form with Lambda and SES

## Overview

Your company's website needs a contact form that users can submit. Instead of managing servers, this project builds a serverless solution that automatically sends emails to your support team. A static HTML contact form submits data to AWS Lambda via API Gateway, and Lambda validates the input and sends the email using Amazon SES.

## Prerequisites

Before starting this project, ensure you have:

1. An AWS account with Lambda, API Gateway, and SES permissions
2. AWS CLI installed and configured
3. Node.js installed locally (for packaging Lambda code)
4. A verified email address in Amazon SES (sandbox mode is fine for testing)
5. Basic understanding of HTTP APIs and email services

## Project Structure

```
AWS Project 3 - Serverless Contact Form/
├── lambda/
│   ├── index.js        # Lambda handler
│   └── package.json    # Node.js dependencies
├── frontend/
│   └── contact.html    # Contact form page
├── deploy.sh           # Automated deployment script
└── README.md
```

## Steps

### 1. Verify Email in Amazon SES

1. Open the SES Console and navigate to Verified identities.
2. Click Create identity and select Email address.
3. Enter the email address that will send and receive form submissions (for example, `you@example.com`).
4. Click Create identity.
5. Check your inbox for a verification link from AWS and click it.

> In sandbox mode, both the sender and recipient addresses must be verified. Request production access when you are ready to send to arbitrary recipients.

### 2. Create IAM Role for Lambda

Create a trust policy allowing Lambda to assume the role, then attach the required policies:

```bash
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
  --assume-role-policy-document file://lambda-trust-policy.json

aws iam attach-role-policy \
  --role-name ContactFormLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > ses-send-policy.json << 'EOF'
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
  --policy-document file://ses-send-policy.json
```

### 3. Deploy the Lambda Function

```bash
cd lambda
zip -r ../function.zip index.js
cd ..

ROLE_ARN=$(aws iam get-role --role-name ContactFormLambdaRole --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name ContactFormHandler \
  --runtime nodejs18.x \
  --role "$ROLE_ARN" \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --timeout 30 \
  --environment Variables="{SENDER_EMAIL=you@example.com,RECIPIENT_EMAIL=you@example.com}"
```

To update the function code after changes:

```bash
cd lambda
zip -r ../function.zip index.js
cd ..

aws lambda update-function-code \
  --function-name ContactFormHandler \
  --zip-file fileb://function.zip
```

### 4. Create API Gateway Endpoint

```bash
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

API_ID=$(aws apigateway create-rest-api \
  --name ContactFormAPI \
  --description "Contact form API" \
  --query 'id' \
  --output text)

ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id $API_ID \
  --query 'items[0].id' \
  --output text)

RESOURCE_ID=$(aws apigateway create-resource \
  --rest-api-id $API_ID \
  --parent-id $ROOT_ID \
  --path-part contact \
  --query 'id' \
  --output text)

# Create POST and OPTIONS methods
aws apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --authorization-type NONE

aws apigateway put-method \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --authorization-type NONE

LAMBDA_ARN=$(aws lambda get-function --function-name ContactFormHandler --query 'Configuration.FunctionArn' --output text)

# Lambda proxy integration for POST
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations"

# MOCK integration for CORS preflight
aws apigateway put-integration \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --type MOCK \
  --request-templates '{"application/json": "{\"statusCode\": 200}"}'

aws apigateway put-method-response \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Headers": true, "method.response.header.Access-Control-Allow-Methods": true, "method.response.header.Access-Control-Allow-Origin": true}'

aws apigateway put-integration-response \
  --rest-api-id $API_ID \
  --resource-id $RESOURCE_ID \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'\''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'\''", "method.response.header.Access-Control-Allow-Methods": "'\''POST,OPTIONS'\''", "method.response.header.Access-Control-Allow-Origin": "'\''*'\''"}'

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission \
  --function-name ContactFormHandler \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/contact"

aws apigateway create-deployment \
  --rest-api-id $API_ID \
  --stage-name prod

API_ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/contact"
echo "API Endpoint: $API_ENDPOINT"
```

### 5. Configure the Frontend

Open `frontend/contact.html` and replace the placeholder value:

```
YOUR_API_GATEWAY_ENDPOINT_HERE
```

with the value of `$API_ENDPOINT` printed in the previous step. If you used `deploy.sh`, this substitution is done automatically.

### 6. Test the Application

Submit a test request via curl:

```bash
curl -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"name":"Test User","email":"test@example.com","message":"Hello from Project 3"}'
```

You should receive a JSON response with `"success": true` and find a new email in your inbox.

## Console Deployment

### 1. Verify Email in Amazon SES

1. Go to **AWS Console → SES → Verified identities**
2. Click **Create identity** → select **Email address**
3. Enter your email address → click **Create identity**
4. Check your inbox for a verification email from AWS and click the link

> **Note:** In SES sandbox mode both the sender and recipient addresses must be verified.

### 2. Create IAM Role for Lambda

1. Go to **IAM → Roles → Create role**
2. **Trusted entity type:** AWS service → **Use case:** Lambda → click **Next**
3. Search and attach **AWSLambdaBasicExecutionRole** → click **Next**
4. **Role name:** `ContactFormLambdaRole` → click **Create role**
5. Open the role → **Add permissions → Create inline policy** → switch to **JSON** tab and paste:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": ["ses:SendEmail", "ses:SendRawEmail"],
       "Resource": "*"
     }]
   }
   ```
6. **Policy name:** `SESSendPolicy` → click **Create policy**

### 3. Create the Lambda Function

1. Go to **Lambda → Create function → Author from scratch**
   - **Function name:** `ContactFormHandler`
   - **Runtime:** Node.js 16.x
2. Under **Permissions → Change default execution role** → **Use an existing role** → select `ContactFormLambdaRole`
3. Click **Create function**
4. In the **Code source** editor, delete the default code and paste the full contents of `lambda/index.js`
5. Click **Deploy**
6. Click **Configuration → Environment variables → Edit** and add:
   - `SENDER_EMAIL` = your verified email
   - `RECIPIENT_EMAIL` = your verified email
7. Click **Save**

### 4. Create API Gateway

1. Go to **API Gateway → Create API → REST API** (not private) → click **Build**
2. **API name:** `ContactFormAPI` → click **Create API**
3. Click **Create resource** → **Resource name:** `contact` → check **CORS** → click **Create resource**
4. With `/contact` selected, click **Create method**
   - **Method type:** POST | **Integration type:** Lambda function | **Lambda proxy integration:** ON
   - **Lambda function:** `ContactFormHandler` → click **Create method** → click **OK** to grant permission
5. With `/contact` selected, click **Enable CORS** → check POST and OPTIONS → click **Save**

### 5. Deploy the API

1. Click **Deploy API** (top right) → **Stage:** `[New stage]` → **Stage name:** `prod` → click **Deploy**
2. Copy the **Invoke URL** — your full contact endpoint is `<Invoke URL>/contact`
3. Open `frontend/contact.html` and replace `YOUR_API_GATEWAY_ENDPOINT_HERE` with your endpoint URL

### Console Cleanup

1. **API Gateway** → select `ContactFormAPI` → **Actions → Delete API**
2. **Lambda** → select `ContactFormHandler` → **Actions → Delete**
3. **IAM → Roles** → delete `ContactFormLambdaRole` (detach/delete policies first)
4. **SES → Verified identities** → delete your verified email identity

---

## CLI / Automation

Use `deploy.sh` to perform all of the above steps automatically:

```bash
# Edit SENDER_EMAIL and RECIPIENT_EMAIL in deploy.sh first
chmod +x deploy.sh
./deploy.sh
```

The script packages `lambda/index.js`, creates the IAM role, deploys the Lambda function, creates and configures API Gateway with CORS, and updates `frontend/contact.html` with the live endpoint.

## Monitoring

Stream Lambda logs to your terminal:

```bash
aws logs tail /aws/lambda/ContactFormHandler --follow
```

## Cleanup

```bash
aws apigateway delete-rest-api --rest-api-id $API_ID
aws lambda delete-function --function-name ContactFormHandler
aws iam delete-role-policy --role-name ContactFormLambdaRole --policy-name SESSendPolicy
aws iam detach-role-policy \
  --role-name ContactFormLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ContactFormLambdaRole
aws ses delete-identity --identity you@example.com
rm -f lambda-trust-policy.json ses-send-policy.json function.zip
```

## Learning Objectives

After completing this project, you will understand:

- Building serverless applications with AWS Lambda
- Integrating Lambda with API Gateway
- Sending emails programmatically with Amazon SES
- Creating IAM roles with least-privilege permissions for Lambda
- Configuring CORS for cross-origin API requests
- Connecting a static HTML frontend to a serverless backend
- Troubleshooting Lambda failures with CloudWatch Logs

## Troubleshooting

| Problem | Solution |
|---|---|
| Email not delivered | Confirm the SES identity is verified and you are in the correct region |
| CORS error in browser | Verify the OPTIONS method and its integration response headers are configured |
| Lambda permission error | Check that the IAM role has `ses:SendEmail` and `ses:SendRawEmail` |
| Lambda invocation fails | Inspect the CloudWatch log group `/aws/lambda/ContactFormHandler` |
| Form shows "Demo Mode" | Replace `YOUR_API_GATEWAY_ENDPOINT_HERE` in `contact.html` with the real endpoint |
