# Project 8: Centralized Logging with CloudWatch and OpenSearch

## Overview

Managing logs from multiple applications and servers scattered across different sources makes troubleshooting difficult. You need a centralized logging solution that aggregates logs from all sources, provides search capabilities, and enables alerting. In this project you will set up Amazon CloudWatch for log collection, create metric filters for detecting issues, and optionally forward logs to OpenSearch for advanced analysis.

## Prerequisites

1. An AWS account with CloudWatch and OpenSearch permissions
2. Running EC2 instances or ECS services generating logs
3. AWS CLI configured with credentials
4. IAM permissions to create roles and policies
5. Basic understanding of logging and monitoring concepts

## Project Structure

```
AWS Project 8 - Centralized Logging/
├── cloudwatch-agent-config.json   # CloudWatch agent configuration
└── dashboard.json                 # CloudWatch dashboard definition
```

## Steps

### Step 1: Create CloudWatch Log Groups

```bash
aws logs create-log-group --log-group-name /aws/application/web-server
aws logs create-log-group --log-group-name /aws/application/api-server
aws logs create-log-group --log-group-name /aws/nginx/access
aws logs create-log-group --log-group-name /aws/nginx/error

# Set 14-day retention on each group
for group in /aws/application/web-server /aws/application/api-server \
             /aws/nginx/access /aws/nginx/error; do
  aws logs put-retention-policy \
    --log-group-name $group \
    --retention-in-days 14
done
```

### Step 2: Install CloudWatch Agent on EC2

```bash
# SSH to your EC2 instance, then:
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
sudo rpm -U ./amazon-cloudwatch-agent.rpm

# Deploy the agent config from this repository
sudo cp cloudwatch-agent-config.json \
  /opt/aws/amazon-cloudwatch-agent/etc/config.json

# Start and enable the agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

sudo systemctl enable amazon-cloudwatch-agent
```

### Step 3: Create Metric Filters

```bash
# Error log filter
aws logs put-metric-filter \
  --log-group-name /aws/application/web-server \
  --filter-name ErrorCount \
  --filter-pattern "[time, request_id, level = ERROR*, ...]" \
  --metric-transformations \
    metricName=ApplicationErrors,metricNamespace=CustomApp,metricValue=1,defaultValue=0

# Nginx 5xx filter
aws logs put-metric-filter \
  --log-group-name /aws/nginx/access \
  --filter-name 5xxErrors \
  --filter-pattern '[ip, id, user, timestamp, request, status_code=5*, size]' \
  --metric-transformations \
    metricName=5xxErrors,metricNamespace=CustomApp,metricValue=1

# API response time filter
aws logs put-metric-filter \
  --log-group-name /aws/application/api-server \
  --filter-name ResponseTime \
  --filter-pattern '[time, request_id, level, message, response_time]' \
  --metric-transformations \
    metricName=APIResponseTime,metricNamespace=CustomApp,metricValue='$response_time',unit=Milliseconds
```

### Step 4: Create CloudWatch Alarms

```bash
# Create an SNS topic for alert emails
TOPIC_ARN=$(aws sns create-topic --name cloudwatch-alerts --query 'TopicArn' --output text)

aws sns subscribe \
  --topic-arn $TOPIC_ARN \
  --protocol email \
  --notification-endpoint your-email@example.com

# High error rate alarm
aws cloudwatch put-metric-alarm \
  --alarm-name high-error-rate \
  --alarm-description "Alert when error rate is high" \
  --metric-name ApplicationErrors \
  --namespace CustomApp \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $TOPIC_ARN

# High CPU alarm
aws cloudwatch put-metric-alarm \
  --alarm-name high-cpu-usage \
  --alarm-description "Alert when CPU usage is high" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $TOPIC_ARN \
  --dimensions Name=InstanceId,Value=i-1234567890abcdef0

# Low disk space alarm
aws cloudwatch put-metric-alarm \
  --alarm-name low-disk-space \
  --alarm-description "Alert when disk space is low" \
  --metric-name DISK_USED \
  --namespace CustomApp \
  --statistic Average \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $TOPIC_ARN
```

### Step 5: Create CloudWatch Dashboard

```bash
# Deploy the dashboard definition from this repository
aws cloudwatch put-dashboard \
  --dashboard-name ApplicationMonitoring \
  --dashboard-body file://dashboard.json
```

### Step 6: Set Up OpenSearch for Advanced Analysis (Optional)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws opensearch create-domain \
  --domain-name application-logs \
  --engine-version OpenSearch_2.11 \
  --cluster-config InstanceType=t3.small.search,InstanceCount=2,ZoneAwarenessEnabled=true \
  --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=20 \
  --node-to-node-encryption-options Enabled=true \
  --encryption-at-rest-options Enabled=true \
  --domain-endpoint-options EnforceHTTPS=true

# Wait 10-15 minutes for the domain to become active
aws opensearch describe-domain \
  --domain-name application-logs \
  --query 'DomainStatus.{Status:Processing,Endpoint:Endpoint}'

OPENSEARCH_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name application-logs \
  --query 'DomainStatus.Endpoint' --output text)
```

### Step 7: Deploy Log Forwarding Lambda (Optional)

```bash
mkdir lambda-log-processor && cd lambda-log-processor

# Create function code that decodes CloudWatch Logs events and bulk-indexes to OpenSearch
cat > index.js << 'EOF'
const zlib = require('zlib');
const https = require('https');

const endpoint = process.env.OPENSEARCH_ENDPOINT;

exports.handler = async (event) => {
    const payload = Buffer.from(event.awslogs.data, 'base64');
    const parsed = JSON.parse(zlib.gunzipSync(payload).toString('utf8'));

    const documents = parsed.logEvents.map(logEvent => ({
        '@timestamp': new Date(logEvent.timestamp).toISOString(),
        message: logEvent.message,
        log_group: parsed.logGroup,
        log_stream: parsed.logStream
    }));

    const bulkBody = documents.flatMap(doc => [
        { index: { _index: 'application-logs' } },
        doc
    ]);

    return sendToOpenSearch('/_bulk', bulkBody);
};

function sendToOpenSearch(path, body) {
    return new Promise((resolve, reject) => {
        const data = JSON.stringify(body);
        const options = {
            hostname: endpoint,
            port: 443,
            path,
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': data.length }
        };
        const req = https.request(options, res => {
            let raw = '';
            res.on('data', chunk => raw += chunk);
            res.on('end', () => resolve(JSON.parse(raw)));
        });
        req.on('error', reject);
        req.write(data);
        req.end();
    });
}
EOF

npm init -y
zip -r function.zip .

# IAM role for the Lambda
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
  --role-name LogProcessorLambdaRole \
  --assume-role-policy-document file://lambda-trust-policy.json

aws iam attach-role-policy \
  --role-name LogProcessorLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

ROLE_ARN=$(aws iam get-role \
  --role-name LogProcessorLambdaRole \
  --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name LogProcessor \
  --runtime nodejs18.x \
  --role $ROLE_ARN \
  --handler index.handler \
  --zip-file fileb://function.zip \
  --timeout 60 \
  --memory-size 256 \
  --environment Variables="{OPENSEARCH_ENDPOINT=$OPENSEARCH_ENDPOINT}"

cd ..
```

### Step 8: Subscribe CloudWatch Logs to Lambda

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)

# Allow CloudWatch Logs to invoke the Lambda
aws lambda add-permission \
  --function-name LogProcessor \
  --statement-id cloudwatch-logs \
  --action lambda:InvokeFunction \
  --principal logs.amazonaws.com \
  --source-arn "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/application/web-server:*"

# Create subscription filter
aws logs put-subscription-filter \
  --log-group-name /aws/application/web-server \
  --filter-name opensearch-filter \
  --filter-pattern "" \
  --destination-arn "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:LogProcessor"
```

## Console Deployment

### 1. Create CloudWatch Log Groups

1. Go to **CloudWatch → Log groups → Create log group**
2. Create four log groups, setting **Retention** to 14 days for each:
   - `/aws/application/web-server`
   - `/aws/application/api-server`
   - `/aws/nginx/access`
   - `/aws/nginx/error`

### 2. Install CloudWatch Agent on EC2

1. Connect to your EC2 instance via **EC2 → Connect → Session Manager**
2. Run the following to install and start the agent:
   ```bash
   wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
   sudo rpm -U ./amazon-cloudwatch-agent.rpm
   sudo cp cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/config.json
   sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
   sudo systemctl enable amazon-cloudwatch-agent
   ```

### 3. Create Metric Filters

1. Go to **CloudWatch → Log groups** → click `/aws/application/web-server`
2. Click **Metric filters → Create metric filter**
   - **Filter pattern:** `[time, request_id, level = ERROR*, ...]`
   - Click **Next** → **Metric namespace:** `CustomApp` | **Metric name:** `ApplicationErrors` | **Metric value:** `1` | **Default value:** `0`
   - Click **Next → Create metric filter**
3. Repeat for `/aws/nginx/access` with pattern `[ip, id, user, timestamp, request, status_code=5*, size]`, metric name `5xxErrors`

### 4. Create SNS Topic for Alerts

1. Go to **SNS → Topics → Create topic** → **Standard** → **Name:** `cloudwatch-alerts` → **Create**
2. Click **Create subscription** → **Protocol:** Email → **Endpoint:** your email → **Create subscription**
3. Confirm the subscription by clicking the link in the email you receive

### 5. Create CloudWatch Alarms

1. Go to **CloudWatch → Alarms → Create alarm → Select metric → CustomApp → ApplicationErrors**
2. **Period:** 5 min | **Statistic:** Sum | **Threshold:** Greater than 10
3. **Send notification to:** select `cloudwatch-alerts` SNS topic
4. **Alarm name:** `high-error-rate` → **Create alarm**
5. Repeat for CPU: **AWS/EC2 → CPUUtilization** → threshold Greater than 80, name `high-cpu-usage`

### 6. Create CloudWatch Dashboard

1. Go to **CloudWatch → Dashboards → Create dashboard** → **Name:** `ApplicationMonitoring` → **Create**
2. Add widgets: click **Add widget** → choose **Line** or **Number** → select metrics from `CustomApp` namespace
3. Click **Save dashboard**

### 7. Set Up OpenSearch Domain (Optional)

1. Go to **OpenSearch Service → Create domain**
   - **Domain name:** `application-logs`
   - **Deployment option:** Multi-AZ | **Instance type:** `t3.small.search` | **Nodes:** 2
   - **EBS storage:** 20 GiB gp3
   - Enable **Node-to-node encryption**, **Encryption at rest**, **Require HTTPS**
2. Click **Create** — takes 10–15 minutes

### Console Cleanup

1. **CloudWatch → Log groups** → delete all four log groups
2. **CloudWatch → Alarms** → delete `high-error-rate` and `high-cpu-usage`
3. **CloudWatch → Dashboards** → delete `ApplicationMonitoring`
4. **SNS → Topics** → delete `cloudwatch-alerts`
5. **OpenSearch** → delete `application-logs` domain (if created)
6. **Lambda** → delete `LogProcessor` (if created)
7. **IAM → Roles** → delete `LogProcessorLambdaRole`

---

## CloudWatch Insights Queries

```bash
# Find all errors in the last hour
aws logs start-query \
  --log-group-name /aws/application/web-server \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 20'

# Average response time by 5-minute bucket
aws logs start-query \
  --log-group-name /aws/application/api-server \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string 'stats avg(response_time), max(response_time) by bin(5m)'

# Request count by HTTP status code
aws logs start-query \
  --log-group-name /aws/nginx/access \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string 'stats count() by status_code'

# Retrieve query results (use the queryId from start-query output)
aws logs get-query-results --query-id <QUERY_ID>
```

## Testing and Validation

```bash
# Verify agent is running on EC2
sudo systemctl status amazon-cloudwatch-agent

# Push a test log event
aws logs put-log-events \
  --log-group-name /aws/application/web-server \
  --log-stream-name test-stream \
  --log-events timestamp=$(date +%s%3N),message='ERROR test error message'

# Check error metric value
aws cloudwatch get-metric-statistics \
  --namespace CustomApp \
  --metric-name ApplicationErrors \
  --start-time $(date -u -d '1 hour ago' --iso-8601) \
  --end-time $(date -u --iso-8601) \
  --period 300 \
  --statistics Sum

# List active alarms
aws cloudwatch describe-alarms --alarm-name-prefix high-
```

## Cleanup

```bash
# Delete subscription filter and Lambda
aws logs delete-subscription-filter \
  --log-group-name /aws/application/web-server \
  --filter-name opensearch-filter

aws lambda delete-function --function-name LogProcessor

# Delete OpenSearch domain
aws opensearch delete-domain --domain-name application-logs

# Delete alarms and SNS topic
aws cloudwatch delete-alarms \
  --alarm-names high-error-rate high-cpu-usage low-disk-space

aws sns delete-topic --topic-arn $TOPIC_ARN

# Delete dashboard
aws cloudwatch delete-dashboards --dashboard-names ApplicationMonitoring

# Delete log groups
for group in /aws/application/web-server /aws/application/api-server \
             /aws/nginx/access /aws/nginx/error; do
  aws logs delete-log-group --log-group-name $group
done

# Delete IAM role
aws iam detach-role-policy \
  --role-name LogProcessorLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name LogProcessorLambdaRole
```

## Learning Objectives

After completing this project you will understand:

- Centralizing logs from multiple sources with CloudWatch
- Creating and configuring CloudWatch Log Groups with retention policies
- Installing and configuring the CloudWatch agent on EC2
- Creating metric filters to extract numeric signals from log text
- Setting up CloudWatch alarms and SNS notifications
- Building CloudWatch dashboards for operational visibility
- Using CloudWatch Insights for ad-hoc log queries
- Forwarding logs to OpenSearch for long-term storage and advanced search
- Implementing log-based metrics and alerting pipelines
