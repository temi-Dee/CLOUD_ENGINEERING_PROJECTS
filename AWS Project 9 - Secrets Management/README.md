# Project 9: Secrets Management with AWS Secrets Manager

## Overview

Your applications contain hardcoded database passwords, API keys, and other sensitive credentials that pose a security risk. You need a centralized, secure way to manage these secrets with automatic rotation and audit trails. In this project you will migrate all credentials to AWS Secrets Manager, implement automatic password rotation for RDS, and integrate secrets into Lambda and ECS applications.

## Prerequisites

1. An AWS account with Secrets Manager and IAM permissions
2. A running RDS instance (from Project 4)
3. Lambda functions or ECS services to integrate with
4. AWS CLI configured with credentials
5. Basic understanding of secret management concepts

## Project Structure

```
AWS Project 9 - Secrets Management/
├── rotation-lambda/
│   ├── index.py          # Secrets Manager rotation Lambda (Python)
│   └── requirements.txt  # Python dependencies (psycopg2-binary, boto3)
└── app-lambda/
    ├── index.js          # Application Lambda that retrieves secrets (Node.js)
    └── package.json
```

## Steps

### Step 1: Create Secrets in Secrets Manager

```bash
# Database credentials secret
aws secretsmanager create-secret \
  --name prod/database/credentials \
  --description "Production database credentials" \
  --secret-string '{
    "username": "dbadmin",
    "password": "SecurePassword123!",
    "host": "mydb.cluster-abc123.us-east-1.rds.amazonaws.com",
    "port": 5432,
    "dbname": "production",
    "dbInstanceIdentifier": "my-rds-instance"
  }'

# Third-party API keys secret
aws secretsmanager create-secret \
  --name prod/api/keys \
  --description "Third-party API keys" \
  --secret-string '{
    "stripe_api_key": "sk_live_xxx",
    "sendgrid_api_key": "SG.xxx"
  }'

# Tag secrets for cost allocation and governance
aws secretsmanager tag-resource \
  --secret-id prod/database/credentials \
  --tags Key=Environment,Value=Production Key=Application,Value=WebApp
```

### Step 2: Deploy the Rotation Lambda

```bash
cd rotation-lambda

# Install dependencies into the current directory for packaging
pip install -r requirements.txt -t .

# Create deployment zip
zip -r rotation-function.zip .

cd ..
```

Create the IAM role and deploy the function:

```bash
cat > rotation-lambda-trust-policy.json << 'EOF'
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
  --role-name SecretsManagerRotationRole \
  --assume-role-policy-document file://rotation-lambda-trust-policy.json

aws iam attach-role-policy \
  --role-name SecretsManagerRotationRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam attach-role-policy \
  --role-name SecretsManagerRotationRole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

cat > rds-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["rds:ModifyDBInstance", "rds:DescribeDBInstances"],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name SecretsManagerRotationRole \
  --policy-name RDSModifyPolicy \
  --policy-document file://rds-policy.json

ROLE_ARN=$(aws iam get-role \
  --role-name SecretsManagerRotationRole \
  --query 'Role.Arn' --output text)

# Deploy Lambda into the same VPC as RDS so it can reach the database
aws lambda create-function \
  --function-name SecretsManagerRotation \
  --runtime python3.11 \
  --role $ROLE_ARN \
  --handler index.lambda_handler \
  --zip-file fileb://rotation-lambda/rotation-function.zip \
  --timeout 30 \
  --vpc-config SubnetIds=subnet-xxx,subnet-yyy,SecurityGroupIds=sg-xxx

# Allow Secrets Manager to invoke the Lambda
aws lambda add-permission \
  --function-name SecretsManagerRotation \
  --statement-id SecretsManagerAccess \
  --action lambda:InvokeFunction \
  --principal secretsmanager.amazonaws.com
```

### Step 3: Enable Automatic Rotation

```bash
LAMBDA_ARN=$(aws lambda get-function \
  --function-name SecretsManagerRotation \
  --query 'Configuration.FunctionArn' --output text)

aws secretsmanager rotate-secret \
  --secret-id prod/database/credentials \
  --rotation-lambda-arn $LAMBDA_ARN \
  --rotation-rules AutomaticallyAfterDays=30
```

### Step 4: Deploy the Application Lambda

```bash
cd app-lambda
npm install
zip -r function.zip .
cd ..

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > lambda-secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": [
      "arn:aws:secretsmanager:us-east-1:${ACCOUNT_ID}:secret:prod/database/credentials-*",
      "arn:aws:secretsmanager:us-east-1:${ACCOUNT_ID}:secret:prod/api/keys-*"
    ]
  }]
}
EOF

aws iam create-role \
  --role-name AppLambdaRole \
  --assume-role-policy-document file://rotation-lambda-trust-policy.json

aws iam attach-role-policy \
  --role-name AppLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam put-role-policy \
  --role-name AppLambdaRole \
  --policy-name SecretsAccessPolicy \
  --policy-document file://lambda-secrets-policy.json

APP_ROLE_ARN=$(aws iam get-role \
  --role-name AppLambdaRole \
  --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name AppWithSecrets \
  --runtime nodejs18.x \
  --role $APP_ROLE_ARN \
  --handler index.handler \
  --zip-file fileb://app-lambda/function.zip \
  --timeout 30
```

### Step 5: Integrate Secrets with ECS

Update your ECS task execution role to read secrets and add `secrets` entries to the container definition:

```bash
cat > ecs-secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "kms:Decrypt"],
    "Resource": [
      "arn:aws:secretsmanager:us-east-1:${ACCOUNT_ID}:secret:prod/*",
      "arn:aws:kms:us-east-1:${ACCOUNT_ID}:key/*"
    ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-name SecretsManagerAccess \
  --policy-document file://ecs-secrets-policy.json
```

Example task definition fragment using secrets injection:

```json
{
  "secrets": [
    {
      "name": "DB_USERNAME",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:prod/database/credentials:username::"
    },
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:prod/database/credentials:password::"
    }
  ]
}
```

### Step 6: Enable Audit Logging

CloudTrail automatically records Secrets Manager API calls. Query recent access with CloudWatch Insights:

```bash
aws logs start-query \
  --log-group-name /aws/cloudtrail \
  --start-time $(date -u -d '7 days ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string '
    fields @timestamp, userIdentity.principalId, eventName, requestParameters.secretId
    | filter eventSource = "secretsmanager.amazonaws.com"
    | filter eventName = "GetSecretValue"
    | sort @timestamp desc
    | limit 100
  '
```

### Step 7: Manage Secret Versions

```bash
# List all versions of a secret
aws secretsmanager list-secret-version-ids \
  --secret-id prod/database/credentials

# Retrieve a specific version
aws secretsmanager get-secret-value \
  --secret-id prod/database/credentials \
  --version-id <VERSION_ID>

# Roll back to the previous version
PREVIOUS_VERSION=$(aws secretsmanager list-secret-version-ids \
  --secret-id prod/database/credentials \
  --query 'Versions[1].VersionId' --output text)

aws secretsmanager update-secret-version-stage \
  --secret-id prod/database/credentials \
  --version-stage AWSCURRENT \
  --move-to-version-id $PREVIOUS_VERSION
```

### Step 8: Replicate Secrets Across Regions (Optional)

```bash
aws secretsmanager replicate-secret-to-regions \
  --secret-id prod/database/credentials \
  --add-replica-regions Region=us-west-2
```

## Console Deployment

### 1. Create Secrets in Secrets Manager

1. Go to **Secrets Manager → Store a new secret**
2. **Secret type:** Other type of secret → **Key/value** pairs → add:
   - `username` = `dbadmin`
   - `password` = your secure password
   - `host` = your RDS endpoint
   - `port` = `5432`
   - `dbname` = `production`
3. Click **Next** → **Secret name:** `prod/database/credentials` → add tags: `Environment=Production`, `Application=WebApp`
4. Click **Next → Next → Store**
5. Repeat to create a second secret named `prod/api/keys` with keys `stripe_api_key` and `sendgrid_api_key`

### 2. Create IAM Role for Rotation Lambda

1. Go to **IAM → Roles → Create role** → AWS service → Lambda → **Next**
2. Attach **AWSLambdaBasicExecutionRole** and **SecretsManagerReadWrite** → **Next**
3. **Role name:** `SecretsManagerRotationRole` → **Create role**
4. Open the role → **Add permissions → Create inline policy** → JSON tab:
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["rds:ModifyDBInstance","rds:DescribeDBInstances"],"Resource":"*"}]}
   ```
   **Policy name:** `RDSModifyPolicy` → **Create policy**

### 3. Create Rotation Lambda

1. Go to **Lambda → Create function → Author from scratch**
   - **Name:** `SecretsManagerRotation` | **Runtime:** Python 3.11
   - **Execution role:** Use existing → `SecretsManagerRotationRole`
2. Paste the contents of `rotation-lambda/index.py` into the code editor → **Deploy**
3. Click **Configuration → Environment variables** → add `SECRETS_MANAGER_ENDPOINT` if needed
4. Go to **Configuration → VPC** → place the Lambda in the same VPC/subnets as your RDS instance

### 4. Enable Automatic Rotation

1. Go to **Secrets Manager → `prod/database/credentials` → Rotation → Edit rotation**
2. Enable **Automatic rotation**
3. **Rotation schedule:** Every 30 days
4. **Rotation function:** select `SecretsManagerRotation`
5. Click **Save**

### 5. Create Application Lambda with Secret Access

1. Go to **IAM → Roles → Create role** → Lambda → **Next**
2. Attach **AWSLambdaBasicExecutionRole** → **Next** → **Role name:** `AppLambdaRole` → **Create**
3. Open the role → **Add permissions → Create inline policy** → JSON:
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":"arn:aws:secretsmanager:us-east-1:*:secret:prod/*"}]}
   ```
   **Policy name:** `SecretsAccessPolicy` → **Create policy**
4. Go to **Lambda → Create function** → **Name:** `AppWithSecrets` | Runtime: Node.js 18.x | Role: `AppLambdaRole`
5. Paste `app-lambda/index.js` into the editor → **Deploy**

### Console Cleanup

1. **Secrets Manager** → `prod/database/credentials` → **Actions → Delete secret** (7-day window)
2. **Secrets Manager** → `prod/api/keys` → **Actions → Delete secret**
3. **Lambda** → delete `SecretsManagerRotation` and `AppWithSecrets`
4. **IAM → Roles** → delete `SecretsManagerRotationRole` and `AppLambdaRole` (detach policies first)

---

## Testing and Validation

```bash
# Retrieve a secret value
aws secretsmanager get-secret-value \
  --secret-id prod/database/credentials \
  --query 'SecretString' --output text

# Invoke the application Lambda
aws lambda invoke \
  --function-name AppWithSecrets \
  --payload '{}' \
  response.json
cat response.json

# Manually trigger a rotation cycle
aws secretsmanager rotate-secret \
  --secret-id prod/database/credentials

# Check rotation status
aws secretsmanager describe-secret \
  --secret-id prod/database/credentials \
  --query '{RotationEnabled:RotationEnabled,LastRotated:LastRotatedDate}'
```

## Cleanup

```bash
# Delete secrets (7-day recovery window)
aws secretsmanager delete-secret \
  --secret-id prod/database/credentials \
  --recovery-window-in-days 7

aws secretsmanager delete-secret \
  --secret-id prod/api/keys \
  --force-delete-without-recovery

# Delete Lambda functions
aws lambda delete-function --function-name SecretsManagerRotation
aws lambda delete-function --function-name AppWithSecrets

# Delete IAM roles
aws iam delete-role-policy \
  --role-name SecretsManagerRotationRole --policy-name RDSModifyPolicy
aws iam detach-role-policy \
  --role-name SecretsManagerRotationRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam detach-role-policy \
  --role-name SecretsManagerRotationRole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
aws iam delete-role --role-name SecretsManagerRotationRole

aws iam delete-role-policy \
  --role-name AppLambdaRole --policy-name SecretsAccessPolicy
aws iam detach-role-policy \
  --role-name AppLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name AppLambdaRole
```

## Learning Objectives

After completing this project you will understand:

- Centralizing credential management with AWS Secrets Manager
- Automatic password rotation using a Lambda rotation function
- Implementing least-privilege IAM policies for secret access
- Integrating secrets into Lambda functions with in-process caching
- Injecting secrets into ECS containers via task definition `secrets` fields
- Encrypting secrets at rest with AWS KMS
- Auditing secret access with CloudTrail and CloudWatch Insights
- Managing secret versions and performing rollbacks
- Replicating secrets across AWS regions for multi-region workloads
