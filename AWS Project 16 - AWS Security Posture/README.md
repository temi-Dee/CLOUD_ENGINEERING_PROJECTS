# Project 16: AWS Security Posture with GuardDuty and Security Hub

## Overview

Securing your AWS infrastructure requires continuous monitoring for threats and compliance violations. Manual security audits are insufficient. You need an automated security monitoring solution that detects threats, identifies misconfigurations, and automates remediation. In this project you will enable GuardDuty for threat detection, Security Hub for compliance aggregation, AWS Config for configuration compliance, AWS Inspector for vulnerability scanning, and automate remediation with Lambda triggered by EventBridge.

## Prerequisites

- AWS account with GuardDuty, Security Hub, Config, and Inspector permissions
- AWS CLI configured with credentials
- Basic understanding of security compliance frameworks (CIS, FSBP)
- Familiarity with Lambda and EventBridge

## Project Structure

```
AWS Project 16 - AWS Security Posture/
├── README.md
├── config-bucket-policy.json       # S3 bucket policy for AWS Config delivery
├── config-trust-policy.json        # IAM trust policy for the Config service role
└── remediation-lambda/
    ├── index.py                    # Lambda function for automated remediation
    └── requirements.txt            # Python dependencies
```

## Steps

### Step 1: Enable GuardDuty

```bash
DETECTOR_ID=$(aws guardduty create-detector \
  --enable \
  --finding-publishing-frequency FIFTEEN_MINUTES \
  --query 'DetectorId' --output text)

echo "GuardDuty Detector ID: $DETECTOR_ID"

# Create sample findings for testing
aws guardduty create-sample-findings \
  --detector-id $DETECTOR_ID \
  --finding-types \
    "UnauthorizedAccess:EC2/SSHBruteForce" \
    "Recon:IAMUser/MaliciousIPCaller" \
    "Policy:S3/BucketPublicAccessGranted"
```

### Step 2: Enable Security Hub

```bash
aws securityhub enable-security-hub --enable-default-standards

# Enable additional compliance standards
aws securityhub batch-enable-standards \
  --standards-subscription-requests \
    StandardsArn=arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0 \
    StandardsArn=arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-benchmark/v/1.2.0
```

### Step 3: Enable AWS Config

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CONFIG_BUCKET="aws-config-${ACCOUNT_ID}"

# Create S3 bucket for Config delivery
aws s3 mb s3://$CONFIG_BUCKET

# Apply bucket policy (config-bucket-policy.json contains the policy template)
# Replace BUCKET_NAME placeholder with the actual bucket name before applying
sed "s/aws-config-BUCKET_NAME/$CONFIG_BUCKET/g" config-bucket-policy.json > /tmp/config-bucket-policy-applied.json
aws s3api put-bucket-policy \
  --bucket $CONFIG_BUCKET \
  --policy file:///tmp/config-bucket-policy-applied.json

# Create Config IAM role using config-trust-policy.json
aws iam create-role \
  --role-name AWSConfigRole \
  --assume-role-policy-document file://config-trust-policy.json

aws iam attach-role-policy \
  --role-name AWSConfigRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole

CONFIG_ROLE_ARN=$(aws iam get-role --role-name AWSConfigRole --query 'Role.Arn' --output text)

# Start Config recorder
aws configservice put-configuration-recorder \
  --configuration-recorder "{
    \"name\": \"default\",
    \"roleARN\": \"$CONFIG_ROLE_ARN\",
    \"recordingGroup\": {
      \"allSupported\": true,
      \"includeGlobalResourceTypes\": true
    }
  }"

# Create delivery channel
aws configservice put-delivery-channel \
  --delivery-channel "{
    \"name\": \"default\",
    \"s3BucketName\": \"$CONFIG_BUCKET\",
    \"configSnapshotDeliveryProperties\": {
      \"deliveryFrequency\": \"TwentyFour_Hours\"
    }
  }"

aws configservice start-configuration-recorder --configuration-recorder-name default
```

### Step 4: Enable AWS Inspector

```bash
aws inspector2 enable \
  --resource-types EC2 ECR LAMBDA

# List critical findings
aws inspector2 list-findings \
  --filter-criteria '{"severity": [{"comparison": "EQUALS", "value": "CRITICAL"}]}' \
  --query 'findings[*].{Title:title,Severity:severity,Resource:resources[0].id}'
```

### Step 5: Create Config Rules

```bash
RULES=(
  "restricted-ssh"
  "restricted-common-ports"
  "s3-bucket-public-read-prohibited"
  "s3-bucket-public-write-prohibited"
  "s3-bucket-server-side-encryption-enabled"
  "encrypted-volumes"
  "rds-storage-encrypted"
  "iam-password-policy"
  "mfa-enabled-for-iam-console-access"
  "root-account-mfa-enabled"
  "cloudtrail-enabled"
  "vpc-flow-logs-enabled"
)

for RULE in "${RULES[@]}"; do
  aws configservice put-config-rule \
    --config-rule "{
      \"ConfigRuleName\": \"$RULE\",
      \"Source\": {
        \"Owner\": \"AWS\",
        \"SourceIdentifier\": \"$(echo $RULE | tr '[:lower:]' '[:upper:]' | tr '-' '_')\"
      }
    }" 2>/dev/null || echo "Rule $RULE may need a different source identifier"
done

# Check compliance status
aws configservice describe-compliance-by-config-rule \
  --query 'ComplianceByConfigRules[*].{Rule:ConfigRuleName,Compliance:Compliance.ComplianceType}' \
  --output table
```

### Step 6: Deploy the Automated Remediation Lambda

The remediation Lambda (`remediation-lambda/index.py`) handles Security Hub findings and auto-remediates S3 public access and open SSH security groups.

```bash
# Create IAM role for the remediation Lambda
cat > remediation-trust-policy.json << 'EOF'
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
  --role-name SecurityRemediationRole \
  --assume-role-policy-document file://remediation-trust-policy.json

aws iam attach-role-policy \
  --role-name SecurityRemediationRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > remediation-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutBucketPublicAccessBlock",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DescribeSecurityGroups",
        "cloudtrail:CreateTrail",
        "cloudtrail:StartLogging",
        "cloudtrail:DescribeTrails",
        "sns:Publish",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name SecurityRemediationRole \
  --policy-name RemediationPolicy \
  --policy-document file://remediation-policy.json

ROLE_ARN=$(aws iam get-role --role-name SecurityRemediationRole --query 'Role.Arn' --output text)

# Create SNS topic for alerts
ALERT_TOPIC=$(aws sns create-topic --name security-alerts --query 'TopicArn' --output text)
aws sns subscribe \
  --topic-arn $ALERT_TOPIC \
  --protocol email \
  --notification-endpoint your-email@example.com

# Package and deploy Lambda
cd remediation-lambda
pip install -r requirements.txt -t ./package
cp index.py ./package/
cd package && zip -r ../function.zip . && cd ..
cd ..

aws lambda create-function \
  --function-name SecurityRemediation \
  --runtime python3.11 \
  --role $ROLE_ARN \
  --handler index.lambda_handler \
  --zip-file fileb://remediation-lambda/function.zip \
  --timeout 60 \
  --environment Variables="{ALERT_TOPIC_ARN=$ALERT_TOPIC}"
```

### Step 7: Connect Security Hub to Lambda via EventBridge

```bash
aws events put-rule \
  --name security-hub-findings \
  --event-pattern '{
    "source": ["aws.securityhub"],
    "detail-type": ["Security Hub Findings - Imported"],
    "detail": {
      "findings": {
        "Severity": {"Label": ["CRITICAL", "HIGH"]},
        "Workflow": {"Status": ["NEW"]},
        "RecordState": ["ACTIVE"]
      }
    }
  }' \
  --state ENABLED

RULE_ARN=$(aws events describe-rule --name security-hub-findings --query 'Arn' --output text)
LAMBDA_ARN=$(aws lambda get-function --function-name SecurityRemediation --query 'Configuration.FunctionArn' --output text)

aws events put-targets \
  --rule security-hub-findings \
  --targets "Id=SecurityRemediationLambda,Arn=$LAMBDA_ARN"

aws lambda add-permission \
  --function-name SecurityRemediation \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn $RULE_ARN
```

### Step 8: Create Security Dashboard

```bash
cat > security-dashboard.json << 'EOF'
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/GuardDuty", "FindingCount", "DetectorId", "DETECTOR_ID", "Severity", "High"],
          ["...", "Severity", "Medium"],
          ["...", "Severity", "Low"]
        ],
        "title": "GuardDuty Findings by Severity",
        "period": 3600,
        "stat": "Sum"
      }
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/SecurityHub", "Findings", "ProductName", "Security Hub"]
        ],
        "title": "Security Hub Findings",
        "period": 3600,
        "stat": "Sum"
      }
    }
  ]
}
EOF

aws cloudwatch put-dashboard \
  --dashboard-name SecurityPosture \
  --dashboard-body file://security-dashboard.json
```

### Step 9: Enable CloudTrail for Audit Logging

```bash
TRAIL_BUCKET="cloudtrail-logs-${ACCOUNT_ID}"
aws s3 mb s3://$TRAIL_BUCKET

cat > trail-bucket-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::$TRAIL_BUCKET"
    },
    {
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/$ACCOUNT_ID/*",
      "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket $TRAIL_BUCKET --policy file://trail-bucket-policy.json

aws cloudtrail create-trail \
  --name production-trail \
  --s3-bucket-name $TRAIL_BUCKET \
  --is-multi-region-trail \
  --enable-log-file-validation \
  --include-global-service-events

aws cloudtrail start-logging --name production-trail
```

## Console Deployment

### 1. Enable GuardDuty

1. Go to **GuardDuty → Get Started → Enable GuardDuty**
2. After enabling, click **Settings → Finding publishing frequency** → set to **15 minutes**
3. To generate sample findings for testing: **Settings → Generate sample findings**

### 2. Enable Security Hub

1. Go to **Security Hub → Go to Security Hub → Enable Security Hub**
2. On the standards page, enable:
   - **AWS Foundational Security Best Practices**
   - **CIS AWS Foundations Benchmark v1.2.0**
3. Click **Enable Security Hub**

### 3. Enable AWS Config

1. Go to **AWS Config → Get started**
2. **Settings:**
   - **Record all resources** supported in this region + global resources
   - **Amazon S3 bucket:** Create a new bucket → name: `aws-config-<account-id>`
   - **IAM role:** Create a role automatically
3. Click **Next → Confirm**

### 4. Add Config Rules

1. Go to **AWS Config → Rules → Add rule**
2. Add each of these managed rules (search by name):
   - `restricted-ssh`, `s3-bucket-public-read-prohibited`, `s3-bucket-server-side-encryption-enabled`
   - `encrypted-volumes`, `iam-password-policy`, `mfa-enabled-for-iam-console-access`, `cloudtrail-enabled`
3. Click **Next → Save** for each rule

### 5. Enable AWS Inspector

1. Go to **Inspector → Get started → Enable Inspector**
2. Select scan types: **EC2 scanning**, **ECR container scanning**, **Lambda function scanning**
3. Click **Enable Inspector**
4. After a few minutes, view findings under **Inspector → Findings**

### 6. Create SNS Alert Topic

1. Go to **SNS → Topics → Create topic** → Standard → **Name:** `security-alerts` → **Create**
2. **Create subscription** → Email → enter your email → confirm from inbox

### 7. Create Remediation Lambda

1. Go to **IAM → Roles → Create role** → Lambda → attach **AWSLambdaBasicExecutionRole** → **Name:** `SecurityRemediationRole` → **Create**
2. Add inline policy with the JSON from the CLI section (S3, EC2, CloudTrail, SNS permissions) → **Name:** `RemediationPolicy`
3. Go to **Lambda → Create function** → **Name:** `SecurityRemediation` | Python 3.11 | Role: `SecurityRemediationRole`
4. Paste `remediation-lambda/index.py` → **Deploy**
5. **Configuration → Environment variables:** `ALERT_TOPIC_ARN` = your SNS topic ARN

### 8. Connect Security Hub → Lambda via EventBridge

1. Go to **EventBridge → Rules → Create rule**
   - **Name:** `security-hub-findings` | **Event bus:** default
2. **Event source:** AWS events → **Service:** Security Hub → **Event type:** Security Hub Findings - Imported
3. Add filter for `Severity.Label` = CRITICAL or HIGH under additional filters → **Next**
4. **Target:** Lambda function → select `SecurityRemediation` → **Create rule**
5. Go to **Lambda → SecurityRemediation → Configuration → Resource-based policy** and confirm EventBridge is listed

### 9. Enable CloudTrail

1. Go to **CloudTrail → Create trail**
   - **Trail name:** `production-trail`
   - **S3 bucket:** Create new → `cloudtrail-logs-<account-id>`
   - Enable **Multi-region trail** + **Log file validation** + **Include global service events**
2. Click **Next → Next → Create trail**

### Console Cleanup

1. **GuardDuty → Settings → Disable GuardDuty** (confirm)
2. **Security Hub → Settings → Disable Security Hub**
3. **AWS Config → Settings → Stop recording** → delete delivery channel → delete recorder
4. **Inspector → Account management → Disable Inspector**
5. **Lambda** → delete `SecurityRemediation`
6. **EventBridge → Rules** → delete `security-hub-findings`
7. **SNS** → delete `security-alerts`
8. **IAM** → delete `SecurityRemediationRole` and `AWSConfigRole`
9. **S3** → empty and delete `aws-config-<account-id>` and `cloudtrail-logs-<account-id>`
10. **CloudTrail** → delete `production-trail`

---

## CLI Automation Summary

The commands above are intended to be run sequentially. Set the following variables at the start of your session:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CONFIG_BUCKET="aws-config-${ACCOUNT_ID}"
TRAIL_BUCKET="cloudtrail-logs-${ACCOUNT_ID}"
```

## Testing and Validation

```bash
# Generate test GuardDuty findings
aws guardduty create-sample-findings \
  --detector-id $DETECTOR_ID \
  --finding-types \
    "UnauthorizedAccess:EC2/SSHBruteForce" \
    "Recon:IAMUser/MaliciousIPCaller"

# Check Security Hub findings
aws securityhub get-findings \
  --filters '{"WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}]}' \
  --query 'Findings[*].{Title:Title,Severity:Severity.Label}' \
  --output table

# Check Config compliance
aws configservice describe-compliance-by-config-rule \
  --compliance-types NON_COMPLIANT \
  --query 'ComplianceByConfigRules[*].ConfigRuleName'
```

## Cleanup

```bash
# Disable GuardDuty
aws guardduty delete-detector --detector-id $DETECTOR_ID

# Disable Security Hub
aws securityhub disable-security-hub

# Stop and delete Config recorder
aws configservice stop-configuration-recorder --configuration-recorder-name default
aws configservice delete-delivery-channel --delivery-channel-name default
aws configservice delete-configuration-recorder --configuration-recorder-name default

# Disable Inspector
aws inspector2 disable --resource-types EC2 ECR LAMBDA

# Delete Lambda
aws lambda delete-function --function-name SecurityRemediation

# Delete EventBridge rule
aws events remove-targets --rule security-hub-findings --ids SecurityRemediationLambda
aws events delete-rule --name security-hub-findings

# Delete SNS topic
aws sns delete-topic --topic-arn $ALERT_TOPIC

# Delete IAM roles
aws iam delete-role-policy --role-name SecurityRemediationRole --policy-name RemediationPolicy
aws iam detach-role-policy \
  --role-name SecurityRemediationRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name SecurityRemediationRole

aws iam detach-role-policy \
  --role-name AWSConfigRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole
aws iam delete-role --role-name AWSConfigRole

# Delete S3 buckets
aws s3 rm s3://$CONFIG_BUCKET --recursive && aws s3 rb s3://$CONFIG_BUCKET
aws s3 rm s3://$TRAIL_BUCKET --recursive && aws s3 rb s3://$TRAIL_BUCKET
```

## Learning Objectives

After completing this project, you will understand:

- Threat detection with GuardDuty (VPC Flow Logs, DNS logs, CloudTrail analysis)
- Compliance monitoring and finding aggregation with Security Hub
- Configuration compliance tracking with AWS Config rules
- Vulnerability scanning with AWS Inspector v2
- Automated remediation patterns using Lambda and EventBridge
- Security finding prioritization and workflow management
- Compliance framework alignment (CIS, FSBP)
- Continuous security monitoring and audit logging with CloudTrail

## Troubleshooting

- **Lambda not triggering**: Check EventBridge rule pattern and Lambda invoke permissions
- **Remediation failing**: Review Lambda CloudWatch logs and IAM role permissions
- **Config rules non-compliant**: Investigate specific resource configurations shown in the console
- **GuardDuty false positives**: Use suppression rules to filter known-safe activity
