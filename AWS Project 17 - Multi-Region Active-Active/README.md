# Project 17: Multi-Region Active-Active Architecture

## Overview

To provide global scale and resilience, applications need to run in multiple AWS regions simultaneously and serve users from the nearest location. A true active-active architecture requires data replication, global traffic management, and a consistent user experience across regions. In this project you will implement global infrastructure with DynamoDB Global Tables, S3 Cross-Region Replication, AWS Global Accelerator, and Route 53 latency-based routing.

## Prerequisites

- AWS account with access to at least two regions
- AWS CLI configured with credentials
- A domain registered in Route 53
- Applications deployed (or ready to deploy) in both the primary and secondary regions
- Understanding of DynamoDB, S3, Route 53, and networking concepts

## Project Structure

```
AWS Project 17 - Multi-Region Active-Active/
├── README.md
├── dynamodb/
│   └── global-table-setup.sh               # Creates DynamoDB Global Table and adds replica region
├── s3-replication/
│   ├── replication-trust-policy.json        # IAM trust policy for the S3 replication role
│   └── replication-policy.json             # IAM permissions policy for S3 replication role
└── global-accelerator/
    └── setup.sh                            # Creates Global Accelerator and listener
```

## Architecture

```
[Global Users]
       |
[AWS Global Accelerator] (Anycast IPs)
      / \
     /   \
[us-east-1]         [eu-west-1]
[ALB + ECS]         [ALB + ECS]
     |                   |
[DynamoDB] <--------> [DynamoDB]
 Global Tables (bi-directional replication)
     |                   |
   [S3 CRR] ----------> [S3]
```

## Steps

### Step 1: Set Environment Variables

```bash
PRIMARY_REGION="us-east-1"
SECONDARY_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Step 2: Deploy Application Infrastructure in Both Regions

Deploy your VPC, ECS cluster, and ALB in both `$PRIMARY_REGION` and `$SECONDARY_REGION` before proceeding. Each region should expose a `/health` endpoint on its ALB.

### Step 3: Create DynamoDB Global Tables

Run the provided setup script, or execute the commands manually:

```bash
bash dynamodb/global-table-setup.sh
```

The script creates the table in the primary region and adds the secondary region as a replica:

```bash
# Create table in primary region with streams enabled (required for Global Tables)
aws dynamodb create-table \
  --table-name global-app-data \
  --attribute-definitions \
    AttributeName=pk,AttributeType=S \
    AttributeName=sk,AttributeType=S \
  --key-schema \
    AttributeName=pk,KeyType=HASH \
    AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region $PRIMARY_REGION

aws dynamodb wait table-exists --table-name global-app-data --region $PRIMARY_REGION

# Add secondary region as a replica (this creates the Global Table)
aws dynamodb update-table \
  --table-name global-app-data \
  --replica-updates "[{\"Create\":{\"RegionName\":\"$SECONDARY_REGION\"}}]" \
  --region $PRIMARY_REGION

# Verify replication status
aws dynamodb describe-table \
  --table-name global-app-data \
  --region $PRIMARY_REGION \
  --query 'Table.Replicas'
```

### Step 4: Set Up S3 Cross-Region Replication

```bash
PRIMARY_BUCKET="app-assets-primary-${ACCOUNT_ID}"
SECONDARY_BUCKET="app-assets-secondary-${ACCOUNT_ID}"

# Create buckets
aws s3 mb s3://$PRIMARY_BUCKET --region $PRIMARY_REGION
aws s3 mb s3://$SECONDARY_BUCKET --region $SECONDARY_REGION

# Enable versioning on both buckets (required for CRR)
aws s3api put-bucket-versioning \
  --bucket $PRIMARY_BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-versioning \
  --bucket $SECONDARY_BUCKET \
  --versioning-configuration Status=Enabled

# Create IAM replication role using the provided policy files
aws iam create-role \
  --role-name S3ReplicationRole \
  --assume-role-policy-document file://s3-replication/replication-trust-policy.json

# Substitute bucket name placeholders and attach the permissions policy
sed -e "s/PRIMARY_BUCKET/$PRIMARY_BUCKET/g" \
    -e "s/SECONDARY_BUCKET/$SECONDARY_BUCKET/g" \
    s3-replication/replication-policy.json > /tmp/replication-policy-applied.json

aws iam put-role-policy \
  --role-name S3ReplicationRole \
  --policy-name ReplicationPolicy \
  --policy-document file:///tmp/replication-policy-applied.json

REPLICATION_ROLE=$(aws iam get-role --role-name S3ReplicationRole --query 'Role.Arn' --output text)

# Configure replication on the primary bucket
aws s3api put-bucket-replication \
  --bucket $PRIMARY_BUCKET \
  --replication-configuration "{
    \"Role\": \"$REPLICATION_ROLE\",
    \"Rules\": [{
      \"ID\": \"ReplicateAll\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"\"},
      \"Destination\": {
        \"Bucket\": \"arn:aws:s3:::$SECONDARY_BUCKET\",
        \"StorageClass\": \"STANDARD\"
      },
      \"DeleteMarkerReplication\": {\"Status\": \"Enabled\"}
    }]
  }"
```

### Step 5: Set Up AWS Global Accelerator

Run the provided setup script, or execute the commands manually:

```bash
bash global-accelerator/setup.sh
```

Then add endpoint groups for each region:

```bash
# Capture the ARNs output by the setup script
ACCELERATOR_ARN="<ARN from setup script output>"
LISTENER_ARN="<ARN from setup script output>"

PRIMARY_ALB=$(aws elbv2 describe-load-balancers \
  --region $PRIMARY_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

SECONDARY_ALB=$(aws elbv2 describe-load-balancers \
  --region $SECONDARY_REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Endpoint group for primary region
aws globalaccelerator create-endpoint-group \
  --listener-arn $LISTENER_ARN \
  --endpoint-group-region $PRIMARY_REGION \
  --traffic-dial-percentage 100 \
  --health-check-path /health \
  --health-check-interval-seconds 10 \
  --threshold-count 3 \
  --endpoint-configurations "[{
    \"EndpointId\": \"$PRIMARY_ALB\",
    \"Weight\": 128,
    \"ClientIPPreservationEnabled\": true
  }]" \
  --region us-west-2

# Endpoint group for secondary region
aws globalaccelerator create-endpoint-group \
  --listener-arn $LISTENER_ARN \
  --endpoint-group-region $SECONDARY_REGION \
  --traffic-dial-percentage 100 \
  --health-check-path /health \
  --health-check-interval-seconds 10 \
  --threshold-count 3 \
  --endpoint-configurations "[{
    \"EndpointId\": \"$SECONDARY_ALB\",
    \"Weight\": 128,
    \"ClientIPPreservationEnabled\": true
  }]" \
  --region us-west-2

echo "Global Accelerator IPs:"
aws globalaccelerator describe-accelerator \
  --accelerator-arn $ACCELERATOR_ARN \
  --region us-west-2 \
  --query 'Accelerator.IpSets[0].IpAddresses'
```

### Step 6: Configure Route 53 Latency-Based Routing

```bash
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query 'HostedZones[0].Id' --output text | cut -d/ -f3)

PRIMARY_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --region $PRIMARY_REGION \
  --query 'LoadBalancers[0].DNSName' --output text)

SECONDARY_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --region $SECONDARY_REGION \
  --query 'LoadBalancers[0].DNSName' --output text)

# Z35SXDOTRQ7X7K = us-east-1 ALB hosted zone ID
# Z32O12XQLNTSW2 = eu-west-1 ALB hosted zone ID
cat > route53-records.json << EOF
{
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.yourdomain.com",
        "Type": "A",
        "SetIdentifier": "primary-us-east-1",
        "Region": "us-east-1",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "$PRIMARY_ALB_DNS",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "app.yourdomain.com",
        "Type": "A",
        "SetIdentifier": "secondary-eu-west-1",
        "Region": "eu-west-1",
        "AliasTarget": {
          "HostedZoneId": "Z32O12XQLNTSW2",
          "DNSName": "$SECONDARY_ALB_DNS",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://route53-records.json
```

### Step 7: Create Route 53 Health Checks and CloudWatch Alarms

```bash
PRIMARY_HC=$(aws route53 create-health-check \
  --caller-reference "primary-$(date +%s)" \
  --health-check-config "{
    \"FullyQualifiedDomainName\": \"$PRIMARY_ALB_DNS\",
    \"Port\": 80,
    \"Type\": \"HTTP\",
    \"ResourcePath\": \"/health\",
    \"RequestInterval\": 10,
    \"FailureThreshold\": 3
  }" \
  --query 'HealthCheck.Id' --output text)

SECONDARY_HC=$(aws route53 create-health-check \
  --caller-reference "secondary-$(date +%s)" \
  --health-check-config "{
    \"FullyQualifiedDomainName\": \"$SECONDARY_ALB_DNS\",
    \"Port\": 80,
    \"Type\": \"HTTP\",
    \"ResourcePath\": \"/health\",
    \"RequestInterval\": 10,
    \"FailureThreshold\": 3
  }" \
  --query 'HealthCheck.Id' --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name primary-region-unhealthy \
  --metric-name HealthCheckStatus \
  --namespace AWS/Route53 \
  --dimensions Name=HealthCheckId,Value=$PRIMARY_HC \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:$ACCOUNT_ID:ops-alerts
```

## Console Deployment

### 1. Deploy Application Infrastructure in Both Regions

Repeat these steps in both `us-east-1` and `eu-west-1`:
- Create a VPC, subnets, security groups, ECS cluster, and ALB in each region
- Ensure each ALB exposes a `/health` endpoint

### 2. Create DynamoDB Global Table

1. Go to **DynamoDB → Tables → Create table** (in us-east-1)
   - **Table name:** `global-app-data`
   - **Partition key:** `pk` (String) | **Sort key:** `sk` (String)
   - **Billing mode:** On-demand
2. Under **Additional settings → DynamoDB Streams:** enable → select **New and old images**
3. Click **Create table** — wait for status Active
4. Open the table → **Global Tables → Create replica**
   - Select `eu-west-1` → **Create replica**
5. Wait for replication status to show **Active** in both regions

### 3. Create S3 Buckets with Cross-Region Replication

1. Go to **S3 → Create bucket** in `us-east-1`
   - **Name:** `app-assets-primary-<account-id>` | enable **Bucket Versioning** → **Create**
2. Create a second bucket in **eu-west-1**
   - **Name:** `app-assets-secondary-<account-id>` | enable **Bucket Versioning** → **Create**
3. Open the primary bucket → **Management → Replication rules → Create replication rule**
   - **Rule name:** `ReplicateAll` | **Status:** Enabled
   - **Source:** All objects
   - **Destination:** `app-assets-secondary-<account-id>` (eu-west-1)
   - **IAM role:** Create new role automatically
   - Enable **Replicate delete markers** → **Save**

### 4. Create AWS Global Accelerator

1. Go to **Global Accelerator → Create accelerator**
   - **Name:** `my-app-accelerator` | **Type:** Standard → **Next**
2. **Listener:** Protocol HTTP | Port 80 → **Next**
3. **Endpoint groups:**
   - Add endpoint group: **Region:** us-east-1 | **Traffic dial:** 100% | **Health check path:** `/health`
   - Add endpoint: select your us-east-1 ALB | **Weight:** 128
   - Add a second endpoint group for eu-west-1 with your eu-west-1 ALB
4. Click **Create accelerator** — note the two static Anycast IP addresses provided

### 5. Configure Route 53 Latency-Based Routing

1. Go to **Route 53 → Hosted zones** → select your domain
2. Click **Create record**
   - **Record name:** `app` | **Record type:** A | **Alias:** ON → select your us-east-1 ALB
   - **Routing policy:** Latency | **Region:** us-east-1 | **Record ID:** `primary-us-east-1`
   - **Evaluate target health:** ON → **Create**
3. Repeat for eu-west-1 ALB: **Record ID:** `secondary-eu-west-1` | **Region:** eu-west-1

### 6. Create Route 53 Health Checks

1. Go to **Route 53 → Health checks → Create health check**
   - **Name:** `primary-health` | **Type:** HTTP | **Domain:** your us-east-1 ALB DNS | **Path:** `/health`
   - **Request interval:** 10 sec | **Failure threshold:** 3 → **Create**
2. Repeat for eu-west-1 ALB → **Name:** `secondary-health`
3. Attach each health check to its corresponding latency record (edit each Route 53 record → select health check)

### Console Cleanup

1. **Global Accelerator** → disable the accelerator → delete listeners → delete accelerator
2. **DynamoDB → global-app-data → Global Tables** → remove eu-west-1 replica → then delete the table
3. **S3** → disable replication rule on primary bucket → empty and delete both buckets
4. **Route 53** → delete the A records for `app.yourdomain.com`
5. **Route 53 → Health checks** → delete both health checks
6. **IAM → Roles** → delete `S3ReplicationRole`

---

## Testing and Validation

```bash
# Test DynamoDB replication: write in primary, read in secondary
aws dynamodb put-item \
  --table-name global-app-data \
  --item '{"pk": {"S": "user#001"}, "sk": {"S": "profile"}, "name": {"S": "Test User"}}' \
  --region $PRIMARY_REGION

sleep 5

aws dynamodb get-item \
  --table-name global-app-data \
  --key '{"pk": {"S": "user#001"}, "sk": {"S": "profile"}}' \
  --region $SECONDARY_REGION

# Simulate primary region failure: set traffic dial to 0%
aws globalaccelerator update-endpoint-group \
  --endpoint-group-arn $PRIMARY_ENDPOINT_GROUP_ARN \
  --traffic-dial-percentage 0 \
  --region us-west-2

# Verify all traffic shifts to secondary
for i in {1..10}; do
  curl -s https://app.yourdomain.com/health | jq .region
  sleep 2
done

# Restore primary
aws globalaccelerator update-endpoint-group \
  --endpoint-group-arn $PRIMARY_ENDPOINT_GROUP_ARN \
  --traffic-dial-percentage 100 \
  --region us-west-2
```

## Cleanup

```bash
# Delete Global Accelerator (must remove listener before accelerator)
aws globalaccelerator delete-listener --listener-arn $LISTENER_ARN --region us-west-2
aws globalaccelerator delete-accelerator --accelerator-arn $ACCELERATOR_ARN --region us-west-2

# Delete DynamoDB Global Table (remove replica first, then table)
aws dynamodb update-table \
  --table-name global-app-data \
  --replica-updates "[{\"Delete\":{\"RegionName\":\"$SECONDARY_REGION\"}}]" \
  --region $PRIMARY_REGION
aws dynamodb delete-table --table-name global-app-data --region $PRIMARY_REGION

# Delete S3 buckets
aws s3 rm s3://$PRIMARY_BUCKET --recursive && aws s3 rb s3://$PRIMARY_BUCKET
aws s3 rm s3://$SECONDARY_BUCKET --recursive && aws s3 rb s3://$SECONDARY_BUCKET

# Delete Route 53 health checks
aws route53 delete-health-check --health-check-id $PRIMARY_HC
aws route53 delete-health-check --health-check-id $SECONDARY_HC

# Delete IAM role
aws iam delete-role-policy --role-name S3ReplicationRole --policy-name ReplicationPolicy
aws iam delete-role --role-name S3ReplicationRole
```

## Learning Objectives

After completing this project, you will understand:

- Global infrastructure design patterns and trade-offs
- RPO/RTO requirements and how architecture decisions affect them
- DynamoDB Global Tables for bi-directional data replication
- S3 Cross-Region Replication for static asset distribution
- AWS Global Accelerator for anycast routing and consistent low-latency entry points
- Route 53 latency-based routing with health checks
- Multi-region failover testing and game-day procedures
- Conflict resolution considerations for active-active writes

## Troubleshooting

- **Replication lag**: Monitor the DynamoDB `ReplicationLatency` CloudWatch metric
- **Failover not triggering**: Check health check thresholds and Route 53 record TTLs
- **Data conflicts**: Review DynamoDB last-writer-wins conflict resolution behavior
- **High latency**: Verify Global Accelerator endpoint health and traffic-dial percentages
