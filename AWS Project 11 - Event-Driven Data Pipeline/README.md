# Project 11: Event-Driven Data Pipeline with SQS, Lambda, and S3

## Overview

Your organization needs to process data events in real-time and store the processed results for later analysis. Instead of polling for work, you want an event-driven architecture where messages automatically trigger processing. In this project you will build a data pipeline where events arrive in SQS, Lambda processes them, and results are stored in S3 partitioned by date and event type for efficient querying.

## Prerequisites

- An AWS account with SQS, Lambda, S3, SNS, IAM, and CloudWatch permissions
- AWS CLI configured with credentials (`aws configure`)
- Node.js 18 or later (for local development)
- Basic understanding of queuing and event-driven architectures
- Familiarity with JSON data formats

## Project Structure

```
AWS Project 11 - Event-Driven Data Pipeline/
├── README.md
└── pipeline-lambda/
    ├── index.js        # Main Lambda handler with idempotency and batch failure support
    └── package.json    # Node.js dependencies
```

## Architecture

```
[Data Producers]
      |
      v
[SQS Main Queue] --> [Lambda: DataPipelineProcessor] --> [S3 Partitioned Output]
      |                                                    processed/
      |                                                    event_type=<type>/
      v                                                    year=YYYY/month=MM/day=DD/
[SQS Dead-Letter Queue] --> [Lambda: DLQProcessor] --> [S3 failed/ prefix]
      |                              |
      v                              v
[CloudWatch Alarm]          [SNS pipeline-alerts topic]
```

## Steps

### Step 1: Create S3 Bucket for Output

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="data-pipeline-output-$ACCOUNT_ID"

aws s3 mb s3://$BUCKET_NAME

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

echo "Bucket: $BUCKET_NAME"
```

### Step 2: Create SQS Queues

```bash
# Create Dead-Letter Queue (DLQ) first
DLQ_URL=$(aws sqs create-queue \
  --queue-name data-pipeline-dlq \
  --attributes '{
    "MessageRetentionPeriod": "1209600",
    "VisibilityTimeout": "300"
  }' \
  --query 'QueueUrl' --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "DLQ ARN: $DLQ_ARN"

# Create main processing queue with long polling and redrive policy
QUEUE_URL=$(aws sqs create-queue \
  --queue-name data-pipeline-queue \
  --attributes "{
    \"VisibilityTimeout\": \"300\",
    \"MessageRetentionPeriod\": \"86400\",
    \"ReceiveMessageWaitTimeSeconds\": \"20\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }" \
  --query 'QueueUrl' --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

echo "Main Queue URL: $QUEUE_URL"
echo "Main Queue ARN: $QUEUE_ARN"
```

### Step 3: Create IAM Role for Lambda

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
  --role-name PipelineLambdaRole \
  --assume-role-policy-document file://lambda-trust-policy.json

aws iam attach-role-policy \
  --role-name PipelineLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > pipeline-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": "$QUEUE_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "$DLQ_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:HeadObject"
      ],
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name PipelineLambdaRole \
  --policy-name PipelinePolicy \
  --policy-document file://pipeline-policy.json

ROLE_ARN=$(aws iam get-role --role-name PipelineLambdaRole --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"
```

### Step 4: Package and Deploy the Main Lambda Function

The Lambda source code is in `pipeline-lambda/index.js`. It processes SQS records in parallel, writes results to S3 partitioned by event type and date, and uses an idempotency check (S3 HeadObject) to avoid duplicate processing. It returns `batchItemFailures` so SQS only retries failed records.

```bash
cd pipeline-lambda
npm install --production
zip -r function.zip .
cd ..

aws lambda create-function \
  --function-name DataPipelineProcessor \
  --runtime nodejs18.x \
  --role $ROLE_ARN \
  --handler index.handler \
  --zip-file fileb://pipeline-lambda/function.zip \
  --timeout 300 \
  --memory-size 512 \
  --environment Variables="{OUTPUT_BUCKET=$BUCKET_NAME}" \
  --reserved-concurrent-executions 10

# Create SQS event source mapping with partial batch failure support
aws lambda create-event-source-mapping \
  --function-name DataPipelineProcessor \
  --event-source-arn $QUEUE_ARN \
  --batch-size 10 \
  --maximum-batching-window-in-seconds 30 \
  --function-response-types ReportBatchItemFailures \
  --scaling-config MaximumConcurrency=5
```

### Step 5: Deploy the DLQ Processor Lambda

The DLQ processor archives failed messages to `s3://$BUCKET_NAME/failed/` and sends an SNS alert.

```bash
# Create SNS topic for alerts
ALERT_TOPIC_ARN=$(aws sns create-topic --name pipeline-alerts --query 'TopicArn' --output text)
aws sns subscribe \
  --topic-arn $ALERT_TOPIC_ARN \
  --protocol email \
  --notification-endpoint your-email@example.com

# Grant the Lambda role permission to publish alerts
cat > sns-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sns:Publish",
    "Resource": "$ALERT_TOPIC_ARN"
  }]
}
EOF

aws iam put-role-policy \
  --role-name PipelineLambdaRole \
  --policy-name SNSPublishPolicy \
  --policy-document file://sns-policy.json

# Create DLQ Lambda inline
mkdir -p dlq-lambda
cat > dlq-lambda/index.js << 'EOF'
const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const sns = new AWS.SNS();

const BUCKET_NAME = process.env.OUTPUT_BUCKET;
const ALERT_TOPIC_ARN = process.env.ALERT_TOPIC_ARN;

exports.handler = async (event) => {
    console.log(`Processing ${event.Records.length} DLQ messages`);

    for (const record of event.Records) {
        const messageId = record.messageId;
        const receiveCount = record.attributes.ApproximateReceiveCount;

        console.error(`DLQ message: ${messageId}, receive count: ${receiveCount}`);

        const key = `failed/${new Date().toISOString().split('T')[0]}/${messageId}.json`;
        await s3.putObject({
            Bucket: BUCKET_NAME,
            Key: key,
            Body: JSON.stringify({
                messageId,
                receiveCount,
                body: (() => { try { return JSON.parse(record.body); } catch { return record.body; } })(),
                failedAt: new Date().toISOString()
            }),
            ContentType: 'application/json'
        }).promise();

        await sns.publish({
            TopicArn: ALERT_TOPIC_ARN,
            Subject: 'Pipeline DLQ Alert',
            Message: `Message ${messageId} failed after ${receiveCount} attempts.\nArchived to: s3://${BUCKET_NAME}/${key}`
        }).promise();
    }
};
EOF

cd dlq-lambda
zip -r function.zip index.js
cd ..

aws lambda create-function \
  --function-name DLQProcessor \
  --runtime nodejs18.x \
  --role $ROLE_ARN \
  --handler index.handler \
  --zip-file fileb://dlq-lambda/function.zip \
  --timeout 60 \
  --environment Variables="{OUTPUT_BUCKET=$BUCKET_NAME,ALERT_TOPIC_ARN=$ALERT_TOPIC_ARN}"

# Connect DLQ to the DLQ processor Lambda
DLQ_ARN_VALUE=$(aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

aws lambda create-event-source-mapping \
  --function-name DLQProcessor \
  --event-source-arn $DLQ_ARN_VALUE \
  --batch-size 5
```

### Step 6: Set Up CloudWatch Monitoring

```bash
# Alarm: messages accumulating in DLQ
aws cloudwatch put-metric-alarm \
  --alarm-name dlq-messages-visible \
  --alarm-description "Messages accumulating in DLQ" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS \
  --dimensions Name=QueueName,Value=data-pipeline-dlq \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions $ALERT_TOPIC_ARN

# Alarm: Lambda processing errors
aws cloudwatch put-metric-alarm \
  --alarm-name pipeline-lambda-errors \
  --alarm-description "Lambda processing errors" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --dimensions Name=FunctionName,Value=DataPipelineProcessor \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $ALERT_TOPIC_ARN

# Alarm: messages waiting too long in the main queue
aws cloudwatch put-metric-alarm \
  --alarm-name queue-message-age \
  --alarm-description "Messages waiting too long in queue" \
  --metric-name ApproximateAgeOfOldestMessage \
  --namespace AWS/SQS \
  --dimensions Name=QueueName,Value=data-pipeline-queue \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 600 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $ALERT_TOPIC_ARN
```

### Step 7: Send Test Messages

```bash
# Send a single test message
aws sqs send-message \
  --queue-url $QUEUE_URL \
  --message-body '{
    "id": "evt-001",
    "eventType": "user_signup",
    "timestamp": "2026-05-25T10:00:00Z",
    "source": "web-app",
    "data": {
      "userId": "user-123",
      "email": "user@example.com",
      "plan": "premium"
    }
  }'

# Send a batch of 10 messages via loop
for i in {1..10}; do
  aws sqs send-message \
    --queue-url $QUEUE_URL \
    --message-body "{
      \"id\": \"evt-$(printf '%03d' $i)\",
      \"eventType\": \"page_view\",
      \"timestamp\": \"$(date -u --iso-8601=seconds)\",
      \"source\": \"web-app\",
      \"data\": {
        \"userId\": \"user-$i\",
        \"page\": \"/home\",
        \"duration\": $((RANDOM % 300))
      }
    }"
  echo "Sent message $i"
done

# Send a batch of 2 messages in one API call
aws sqs send-message-batch \
  --queue-url $QUEUE_URL \
  --entries '[
    {"Id":"1","MessageBody":"{\"id\":\"batch-1\",\"eventType\":\"purchase\",\"timestamp\":\"2026-05-25T10:00:00Z\",\"data\":{\"amount\":99.99}}"},
    {"Id":"2","MessageBody":"{\"id\":\"batch-2\",\"eventType\":\"purchase\",\"timestamp\":\"2026-05-25T10:01:00Z\",\"data\":{\"amount\":49.99}}"}
  ]'
```

### Step 8: Verify Output in S3

```bash
# List all processed files
aws s3 ls s3://$BUCKET_NAME/processed/ --recursive

# View a specific processed file
aws s3 cp s3://$BUCKET_NAME/processed/event_type=user_signup/year=2026/month=05/day=25/evt-001.json -

# Count files by event type
aws s3 ls s3://$BUCKET_NAME/processed/ --recursive | grep -oP 'event_type=\K[^/]+' | sort | uniq -c
```

## Console Deployment

### 1. Create S3 Output Bucket

1. Go to **S3 → Create bucket**
   - **Name:** `data-pipeline-output-<your-account-id>` | enable **Bucket Versioning**
2. Click **Create bucket**

### 2. Create SQS Dead-Letter Queue

1. Go to **SQS → Create queue** → **Standard**
   - **Name:** `data-pipeline-dlq`
   - **Message retention:** 14 days | **Visibility timeout:** 300 seconds
2. Click **Create queue** — copy the queue ARN

### 3. Create SQS Main Queue

1. Go to **SQS → Create queue** → **Standard**
   - **Name:** `data-pipeline-queue`
   - **Visibility timeout:** 300 sec | **Message retention:** 1 day
   - **Receive message wait time:** 20 seconds (enables long polling)
2. Under **Dead-letter queue** → enable → select `data-pipeline-dlq` → **Maximum receives:** 3
3. Click **Create queue** — copy the queue ARN

### 4. Create IAM Role for Lambda

1. Go to **IAM → Roles → Create role** → Lambda → **Next**
2. Attach **AWSLambdaBasicExecutionRole** → **Next** → **Name:** `PipelineLambdaRole` → **Create**
3. Open the role → **Add permissions → Create inline policy** → JSON:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","sqs:ChangeMessageVisibility"],"Resource":"<MAIN_QUEUE_ARN>"},
       {"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],"Resource":"<DLQ_ARN>"},
       {"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:HeadObject"],"Resource":"arn:aws:s3:::data-pipeline-output-<account-id>/*"}
     ]
   }
   ```
   Replace ARNs and account ID → **Policy name:** `PipelinePolicy` → **Create**

### 5. Create Main Lambda Function

1. Go to **Lambda → Create function → Author from scratch**
   - **Name:** `DataPipelineProcessor` | **Runtime:** Node.js 18.x | **Role:** `PipelineLambdaRole`
2. Paste `pipeline-lambda/index.js` into the editor → **Deploy**
3. **Configuration → General configuration → Edit**: **Timeout:** 5 min | **Memory:** 512 MB | **Reserved concurrency:** 10
4. **Configuration → Environment variables**: `OUTPUT_BUCKET` = your bucket name
5. **Configuration → Triggers → Add trigger** → **SQS**
   - **Queue:** `data-pipeline-queue` | **Batch size:** 10 | **Batching window:** 30s
   - Enable **Report batch item failures** → **Add**

### 6. Create SNS Alert Topic

1. Go to **SNS → Topics → Create topic** → Standard → **Name:** `pipeline-alerts` → **Create**
2. Click **Create subscription** → Email → enter your email → confirm from your inbox

### 7. Create DLQ Processor Lambda

1. Go to **Lambda → Create function** → **Name:** `DLQProcessor` | Node.js 18.x | Role: `PipelineLambdaRole`
2. Paste the inline DLQ handler code from the CLI section → **Deploy**
3. **Environment variables:** `OUTPUT_BUCKET` = your bucket, `ALERT_TOPIC_ARN` = your SNS ARN
4. Add IAM inline policy to `PipelineLambdaRole` for `sns:Publish` on the topic ARN
5. **Triggers → Add trigger → SQS** → queue: `data-pipeline-dlq` | batch size: 5 → **Add**

### 8. Create CloudWatch Alarms

1. Go to **CloudWatch → Alarms → Create alarm → Select metric → SQS → Per-Queue Metrics**
2. Select `data-pipeline-dlq` → **ApproximateNumberOfMessagesVisible** → **Select metric**
   - Threshold: GreaterThanOrEqualToThreshold → 1 | SNS action: `pipeline-alerts`
   - **Name:** `dlq-messages-visible` → **Create**
3. Repeat for Lambda **Errors** > 5 on `DataPipelineProcessor` → name: `pipeline-lambda-errors`

### 9. Send Test Messages

1. Go to **SQS → data-pipeline-queue → Send and receive messages**
2. Paste a test message body and click **Send message**:
   ```json
   {"id":"evt-001","eventType":"user_signup","timestamp":"2026-05-26T10:00:00Z","source":"web-app","data":{"userId":"user-123","email":"user@example.com"}}
   ```

### Console Cleanup

1. **Lambda** → delete `DataPipelineProcessor` and `DLQProcessor` (remove triggers first)
2. **SQS** → delete `data-pipeline-queue` then `data-pipeline-dlq`
3. **S3** → empty and delete `data-pipeline-output-<account-id>`
4. **SNS** → delete `pipeline-alerts`
5. **CloudWatch → Alarms** → delete `dlq-messages-visible` and `pipeline-lambda-errors`
6. **IAM → Roles** → delete `PipelineLambdaRole`

---

## CLI / Automation Reference

### CloudWatch Insights Queries

```bash
# Average and max Lambda processing duration over the past hour
aws logs start-query \
  --log-group-name /aws/lambda/DataPipelineProcessor \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string 'stats avg(duration), max(duration), count() by bin(5m)'

# Error analysis for the past hour
aws logs start-query \
  --log-group-name /aws/lambda/DataPipelineProcessor \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc'
```

## Cleanup

```bash
# Delete event source mappings
for uuid in $(aws lambda list-event-source-mappings \
  --function-name DataPipelineProcessor \
  --query 'EventSourceMappings[*].UUID' --output text); do
  aws lambda delete-event-source-mapping --uuid $uuid
done

for uuid in $(aws lambda list-event-source-mappings \
  --function-name DLQProcessor \
  --query 'EventSourceMappings[*].UUID' --output text); do
  aws lambda delete-event-source-mapping --uuid $uuid
done

# Delete Lambda functions
aws lambda delete-function --function-name DataPipelineProcessor
aws lambda delete-function --function-name DLQProcessor

# Delete SQS queues
aws sqs delete-queue --queue-url $QUEUE_URL
aws sqs delete-queue --queue-url $DLQ_URL

# Empty and delete S3 bucket
aws s3 rm s3://$BUCKET_NAME --recursive
aws s3 rb s3://$BUCKET_NAME

# Delete SNS topic
aws sns delete-topic --topic-arn $ALERT_TOPIC_ARN

# Delete CloudWatch alarms
aws cloudwatch delete-alarms \
  --alarm-names dlq-messages-visible pipeline-lambda-errors queue-message-age

# Delete IAM role and policies
aws iam delete-role-policy --role-name PipelineLambdaRole --policy-name PipelinePolicy
aws iam delete-role-policy --role-name PipelineLambdaRole --policy-name SNSPublishPolicy
aws iam detach-role-policy --role-name PipelineLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name PipelineLambdaRole
```

## Testing / Validation

1. After sending test messages, run `aws s3 ls s3://$BUCKET_NAME/processed/ --recursive` and confirm files appear under the `event_type=user_signup/` prefix within 30 seconds.
2. Send a message with a duplicate `id` and confirm the Lambda logs "already processed, skipping" and does not overwrite the S3 object.
3. Send a malformed message (missing `eventType`) and confirm it eventually lands in the DLQ and the DLQ processor archives it under `s3://$BUCKET_NAME/failed/`.
4. Check the `dlq-messages-visible` CloudWatch alarm fires when a message arrives in the DLQ.

## Learning Objectives

After completing this project, you will understand:

- Event-driven architecture patterns and SQS-triggered Lambda
- SQS queue configuration: visibility timeout, retention, long polling, and redrive policy
- Dead-letter queue pattern for error isolation and diagnosis
- Partial batch failure responses to avoid reprocessing successful records
- S3 data partitioning by event type and date for efficient Athena queries
- Idempotent processing using S3 HeadObject checks
- CloudWatch alarms and SNS notifications for pipeline health
- IAM least-privilege design for Lambda functions

## Troubleshooting

- **Messages stuck in queue**: Check Lambda concurrency limits and CloudWatch Logs for errors
- **DLQ filling up**: Review Lambda logs for processing errors; check IAM permissions on S3
- **Duplicate records in S3**: Verify the idempotency logic (`ensureObjectNotExists`) is working
- **High Lambda duration**: Reduce batch size or increase memory allocation
