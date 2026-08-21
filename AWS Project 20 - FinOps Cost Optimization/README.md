# Project 20: FinOps - Cost Optimization and Accountability

## Overview

Cloud costs can grow invisibly — unused resources, poorly sized instances, and inefficient architectures add up quickly. FinOps brings financial accountability to cloud engineering by making costs visible, providing optimization opportunities, and holding teams responsible for their consumption. In this project you will implement a comprehensive cost management program with tagging governance, AWS Budgets, waste detection automation, anomaly detection, and Compute Optimizer integration.

## Prerequisites

- AWS account with billing and Cost Explorer permissions enabled
- AWS Organizations configured (required for tagging policies and SCPs)
- AWS CLI configured with appropriate credentials
- IAM permissions for Cost Explorer, Budgets, and Compute Optimizer
- SNS topic for billing alerts (created in Step 5)

## Project Structure

```
AWS Project 20 - FinOps Cost Optimization/
├── README.md
├── tagging-policy.json          # AWS Organizations tag policy (enforces required tags)
├── enforce-tags-scp.json        # Service Control Policy blocking untagged resource creation
├── monthly-budget.json          # AWS Budgets definition for the monthly organization budget
├── budget-notifications.json    # Notification thresholds (75%, 90% actual; 100% forecasted)
├── team-budget.json             # Per-team budget filtered by the Team cost allocation tag
└── waste-detector.py           # Lambda function that detects idle and unused resources
```

## Steps

### Step 1: Enable Cost Explorer and Activate Cost Allocation Tags

```bash
# Verify Cost Explorer access
aws ce get-cost-and-usage \
  --time-period Start=2026-05-01,End=2026-05-02 \
  --granularity DAILY \
  --metrics BlendedCost

# Activate tags for cost allocation (tags must exist on resources first)
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status \
    TagKey=Environment,Status=Active \
    TagKey=Team,Status=Active \
    TagKey=Application,Status=Active \
    TagKey=CostCenter,Status=Active
```

### Step 2: Create the Organization Tagging Policy

The `tagging-policy.json` file defines required tags for EC2, RDS, S3, Lambda, and ECS resources.

```bash
# Create the tag policy in AWS Organizations
TAG_POLICY_ID=$(aws organizations create-policy \
  --content file://tagging-policy.json \
  --description "Mandatory cost allocation tags" \
  --name RequiredCostAllocationTags \
  --type TAG_POLICY \
  --query 'Policy.PolicySummary.Id' --output text)

# Attach to the organization root
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
aws organizations attach-policy \
  --policy-id $TAG_POLICY_ID \
  --target-id $ROOT_ID
```

### Step 3: Create a Config Rule for Tag Compliance Reporting

```bash
aws configservice put-config-rule \
  --config-rule '{
    "ConfigRuleName": "required-tags-compliance",
    "Source": {
      "Owner": "AWS",
      "SourceIdentifier": "REQUIRED_TAGS"
    },
    "InputParameters": "{\"tag1Key\":\"Environment\",\"tag2Key\":\"Team\",\"tag3Key\":\"Application\",\"tag4Key\":\"CostCenter\"}",
    "Scope": {
      "ComplianceResourceTypes": [
        "AWS::EC2::Instance",
        "AWS::RDS::DBInstance",
        "AWS::S3::Bucket",
        "AWS::Lambda::Function"
      ]
    }
  }'
```

### Step 4: Apply the SCP to Block Untagged Resource Creation

The `enforce-tags-scp.json` file denies EC2, RDS, S3, and Lambda creation when required tags are absent.

```bash
SCP_ID=$(aws organizations create-policy \
  --content file://enforce-tags-scp.json \
  --description "Deny resource creation without required cost allocation tags" \
  --name EnforceCostAllocationTags \
  --type SERVICE_CONTROL_POLICY \
  --query 'Policy.PolicySummary.Id' --output text)

aws organizations attach-policy \
  --policy-id $SCP_ID \
  --target-id $ROOT_ID
```

### Step 5: Create the SNS Alert Topic and Monthly Budget

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

SNS_TOPIC_ARN=$(aws sns create-topic \
  --name billing-alerts \
  --query 'TopicArn' --output text)

aws sns subscribe \
  --topic-arn $SNS_TOPIC_ARN \
  --protocol email \
  --notification-endpoint finance-team@example.com

# Substitute the real SNS ARN into the notifications file before deploying
sed "s|arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:billing-alerts|$SNS_TOPIC_ARN|g" \
  budget-notifications.json > /tmp/budget-notifications-applied.json

# Deploy the monthly organization budget with the notification thresholds
aws budgets create-budget \
  --account-id $ACCOUNT_ID \
  --budget file://monthly-budget.json \
  --notifications-with-subscribers file:///tmp/budget-notifications-applied.json
```

### Step 6: Create a Per-Team Budget

The `team-budget.json` file creates a $5,000/month budget scoped to resources tagged `Team=Engineering`.

```bash
aws budgets create-budget \
  --account-id $ACCOUNT_ID \
  --budget file://team-budget.json
```

### Step 7: Enable Cost Anomaly Detection

```bash
MONITOR_ARN=$(aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "ServiceLevelSpendMonitor",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }' \
  --query 'MonitorArn' --output text)

aws ce create-anomaly-subscription \
  --anomaly-subscription "{
    \"SubscriptionName\": \"DailyAnomalyAlerts\",
    \"MonitorArnList\": [\"$MONITOR_ARN\"],
    \"Subscribers\": [{
      \"Type\": \"SNS\",
      \"Address\": \"$SNS_TOPIC_ARN\"
    }],
    \"Threshold\": 100,
    \"Frequency\": \"DAILY\"
  }"
```

### Step 8: Enable Compute Optimizer

```bash
# Opt in to Compute Optimizer
aws compute-optimizer update-enrollment-status --status Active

# Get EC2 rightsizing recommendations
aws compute-optimizer get-ec2-instance-recommendations \
  --filter name=finding,values=Underprovisioned,Overprovisioned \
  --query 'instanceRecommendations[*].{
    Instance:instanceArn,
    Current:currentInstanceType,
    Recommended:recommendationOptions[0].instanceType,
    Savings:recommendationOptions[0].estimatedMonthlySavings.value
  }' \
  --output table

# Get Lambda memory recommendations
aws compute-optimizer get-lambda-function-recommendations \
  --query 'lambdaFunctionRecommendations[*].{
    Function:functionArn,
    CurrentMemory:currentMemorySize,
    Recommended:memorySizeRecommendationOptions[0].memorySize,
    Savings:memorySizeRecommendationOptions[0].estimatedMonthlySavings.value
  }' \
  --output table
```

### Step 9: Deploy the Cost Waste Detector Lambda

The `waste-detector.py` function detects unattached EBS volumes, unused Elastic IPs, old snapshots, idle EC2 instances, and empty S3 buckets, then publishes a report to SNS.

```bash
# Package the function
zip waste-detector.zip waste-detector.py

# Create an IAM role for the Lambda
cat > waste-detector-trust-policy.json << 'EOF'
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
  --role-name WasteDetectorRole \
  --assume-role-policy-document file://waste-detector-trust-policy.json

aws iam attach-role-policy \
  --role-name WasteDetectorRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > waste-detector-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
      "ec2:DescribeInstances",
      "cloudwatch:GetMetricStatistics",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "sns:Publish"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name WasteDetectorRole \
  --policy-name WasteDetectorPolicy \
  --policy-document file://waste-detector-policy.json

WASTE_ROLE_ARN=$(aws iam get-role \
  --role-name WasteDetectorRole --query 'Role.Arn' --output text)

# Deploy Lambda
aws lambda create-function \
  --function-name CostWasteDetector \
  --runtime python3.11 \
  --role $WASTE_ROLE_ARN \
  --handler waste-detector.lambda_handler \
  --zip-file fileb://waste-detector.zip \
  --timeout 300 \
  --environment Variables="{SNS_TOPIC_ARN=$SNS_TOPIC_ARN}"

# Schedule weekly scans (Mondays at 09:00 UTC)
aws events put-rule \
  --name weekly-cost-scan \
  --schedule-expression "cron(0 9 ? * MON *)" \
  --state ENABLED

SCAN_RULE_ARN=$(aws events describe-rule \
  --name weekly-cost-scan --query 'Arn' --output text)
WASTE_LAMBDA_ARN=$(aws lambda get-function \
  --function-name CostWasteDetector \
  --query 'Configuration.FunctionArn' --output text)

aws events put-targets \
  --rule weekly-cost-scan \
  --targets "Id=WasteDetector,Arn=$WASTE_LAMBDA_ARN"

aws lambda add-permission \
  --function-name CostWasteDetector \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn $SCAN_RULE_ARN
```

### Step 10: Review Savings Plans and Reserved Instance Coverage

```bash
# Get Savings Plans purchase recommendations
aws ce get-savings-plans-purchase-recommendation \
  --savings-plans-type COMPUTE_SP \
  --term-in-years ONE_YEAR \
  --payment-option NO_UPFRONT \
  --lookback-period-in-days SIXTY_DAYS

# Get Reserved Instance coverage report
aws ce get-reservation-coverage \
  --time-period Start=2026-04-01,End=2026-05-01 \
  --granularity MONTHLY
```

## Console Deployment

### 1. Enable Cost Explorer and Activate Cost Allocation Tags

1. Go to **Billing and Cost Management → Cost Explorer → Enable Cost Explorer**
2. Go to **Billing → Cost allocation tags**
3. Under **AWS-generated cost allocation tags**, activate: `Environment`, `Team`, `Application`, `CostCenter`
4. Click **Activate** — tags appear in Cost Explorer after up to 24 hours

### 2. Create SNS Alert Topic

1. Go to **SNS → Topics → Create topic** → Standard → **Name:** `billing-alerts` → **Create**
2. **Create subscription** → Email → enter your finance email → confirm from inbox

### 3. Create Monthly Budget

1. Go to **Budgets → Create budget**
2. **Budget type:** Cost budget | **Name:** `Monthly-Total-Budget`
3. **Budgeted amount:** set your monthly limit (e.g. $500) | **Period:** Monthly
4. **Alerts:**
   - Add alert: 75% of budgeted amount → notify SNS topic `billing-alerts`
   - Add alert: 90% of budgeted amount → notify SNS topic
   - Add alert: 100% forecasted → notify SNS topic
5. Click **Create budget**

### 4. Create Per-Team Budget

1. **Budgets → Create budget** → Cost budget → **Name:** `Team-Engineering-Budget`
2. **Budgeted amount:** $5,000 | **Filter:** Tag: Team = Engineering
3. Add alert at 80% → notify `billing-alerts` → **Create budget**

### 5. Enable Cost Anomaly Detection

1. Go to **Cost Explorer → Cost Anomaly Detection → Create monitor**
   - **Monitor type:** AWS services | **Name:** `ServiceLevelSpendMonitor` → **Create**
2. Click **Create subscription**
   - **Name:** `DailyAnomalyAlerts` | **Threshold:** $100 | **Frequency:** Daily
   - **Alert recipients:** SNS topic `billing-alerts` → **Create**

### 6. Enable Compute Optimizer

1. Go to **Compute Optimizer → Get started → Opt in** (or **Activate Compute Optimizer**)
2. After 24–48 hours of data collection, go to:
   - **EC2 instances** — view over/under-provisioned instance recommendations
   - **Lambda functions** — view memory size recommendations
   - Each card shows estimated monthly savings

### 7. Create Waste Detector Lambda

1. Go to **IAM → Roles → Create role** → Lambda → attach **AWSLambdaBasicExecutionRole** → **Name:** `WasteDetectorRole`
2. Add inline policy with the JSON from the CLI section (EC2, S3, CloudWatch, SNS permissions) → **Name:** `WasteDetectorPolicy`
3. Go to **Lambda → Create function** → **Name:** `CostWasteDetector` | Python 3.11 | Role: `WasteDetectorRole`
4. Paste `waste-detector.py` → **Deploy**
5. **Configuration → Environment variables:** `SNS_TOPIC_ARN` = your billing-alerts ARN
6. **Configuration → General configuration:** **Timeout:** 5 minutes
7. Go to **EventBridge → Rules → Create rule** → **Schedule expression:** `cron(0 9 ? * MON *)` → **Target:** `CostWasteDetector` → **Create**

### 8. Set Up Tagging Policy in AWS Organizations (Optional)

1. Go to **AWS Organizations → Policies → Tag policies → Create policy**
2. Paste the contents of `tagging-policy.json` → **Save changes**
3. Go to **AWS Organizations → Root → Policies** → attach the tag policy

### Console Cleanup

1. **Budgets** → delete `Monthly-Total-Budget` and `Team-Engineering-Budget`
2. **Cost Anomaly Detection** → delete subscription and monitor
3. **Lambda** → delete `CostWasteDetector`
4. **EventBridge → Rules** → delete `weekly-cost-scan`
5. **SNS** → delete `billing-alerts`
6. **IAM → Roles** → delete `WasteDetectorRole`
7. **AWS Organizations** → detach and delete tagging policy (if created)

---

## FinOps Framework

```
[Cloud Cost Visibility]
         |
[Cost Allocation Tags] ---> [Team Budgets] ---> [Alerts]
         |
[Anomaly Detection]
         |
[Waste Identification] ---> [Rightsizing Recommendations]
         |
[Cost Optimization Realized]
```

## Testing and Validation

```bash
# Trigger the waste detector manually
aws lambda invoke \
  --function-name CostWasteDetector \
  --log-type Tail \
  response.json
cat response.json

# Check tag compliance in Config
aws configservice describe-compliance-by-config-rule \
  --config-rule-names required-tags-compliance \
  --compliance-types NON_COMPLIANT \
  --query 'ComplianceByConfigRules[*].{Rule:ConfigRuleName,Status:Compliance.ComplianceType}'

# View current cost and usage by team tag
aws ce get-cost-and-usage \
  --time-period Start=2026-05-01,End=2026-05-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Team
```

## Cleanup

```bash
# Delete budgets
aws budgets delete-budget \
  --account-id $ACCOUNT_ID --budget-name Monthly-Total-Budget
aws budgets delete-budget \
  --account-id $ACCOUNT_ID --budget-name Team-Engineering-Budget

# Delete Lambda and EventBridge rule
aws events remove-targets --rule weekly-cost-scan --ids WasteDetector
aws events delete-rule --name weekly-cost-scan
aws lambda delete-function --function-name CostWasteDetector

# Delete IAM role
aws iam delete-role-policy \
  --role-name WasteDetectorRole --policy-name WasteDetectorPolicy
aws iam detach-role-policy \
  --role-name WasteDetectorRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name WasteDetectorRole

# Delete SNS topic
aws sns delete-topic --topic-arn $SNS_TOPIC_ARN

# Detach and delete Organizations policies
aws organizations detach-policy --policy-id $TAG_POLICY_ID --target-id $ROOT_ID
aws organizations delete-policy --policy-id $TAG_POLICY_ID

aws organizations detach-policy --policy-id $SCP_ID --target-id $ROOT_ID
aws organizations delete-policy --policy-id $SCP_ID
```

## Learning Objectives

After completing this project, you will understand:

- FinOps principles and building a cost-accountability culture across teams
- Cost allocation tagging strategy and enforcement via tag policies and SCPs
- AWS Budgets for organization-wide and per-team spend controls
- Cost anomaly detection to identify unexpected spend spikes automatically
- Compute Optimizer for EC2 and Lambda rightsizing recommendations
- Waste identification (unattached EBS, unused EIPs, idle EC2) with automated Lambda reporting
- Savings Plans and Reserved Instance coverage analysis
- Chargeback and showback models using Cost Explorer tag-based grouping

## Troubleshooting

- **Tags not appearing in Cost Explorer**: Allow up to 24 hours after activating a cost allocation tag
- **Budget alerts not sending**: Confirm the SNS subscription email was confirmed by the recipient
- **Compute Optimizer shows no recommendations**: Ensure at least 14 days of CloudWatch metrics exist for the resources
- **Lambda timing out on large accounts**: Increase the timeout to 300 seconds and consider processing resources in paginated batches
- **SCP blocking legitimate operations**: Review the SCP conditions carefully; use `aws:RequestTag` (not `aws:ResourceTag`) for creation-time enforcement
