# Project 10: Auto Scaling Web Tier with ALB and ASG

## Overview

Your web application experiences variable traffic throughout the day, and you need infrastructure that automatically scales up during peak hours and down during off-peak times. Manually adjusting capacity is inefficient and costly. In this project you will implement horizontal auto-scaling using an Application Load Balancer and Auto Scaling Group that automatically adjusts instance count based on demand.

## Prerequisites

1. An AWS account with EC2, ALB, and Auto Scaling permissions
2. AWS CLI configured with credentials
3. A VPC with at least two public and two private subnets
4. Basic understanding of load balancing and scaling concepts

## Project Structure

```
AWS Project 10 - Auto Scaling Web Tier/
└── scripts/
    ├── user-data.sh    # EC2 bootstrap script (Nginx + health endpoint)
    └── create-asg.sh   # Creates launch template and Auto Scaling Group
```

## Architecture

```
[Internet]
    |
[Application Load Balancer - Multi-AZ]
    |          |
[EC2]        [EC2]   <-- Auto Scaling Group (min 2, max 10)
```

## Steps

### Step 1: Create Security Groups

Export your VPC ID first, then run:

```bash
# ALB security group - allow HTTP/HTTPS from the internet
ALB_SG=$(aws ec2 create-security-group \
  --group-name alb-sg \
  --description "ALB Security Group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0

# EC2 security group - allow traffic only from ALB
EC2_SG=$(aws ec2 create-security-group \
  --group-name ec2-web-sg \
  --description "EC2 Web Server Security Group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG --protocol tcp --port 80 --source-group $ALB_SG
# Replace YOUR_IP with your actual IP address for SSH access
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG --protocol tcp --port 22 --cidr YOUR_IP/32
```

### Step 2: Create IAM Role for EC2

```bash
cat > ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name WebServerRole \
  --assume-role-policy-document file://ec2-trust-policy.json

aws iam attach-role-policy \
  --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam attach-role-policy \
  --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile \
  --instance-profile-name WebServerProfile

aws iam add-role-to-instance-profile \
  --instance-profile-name WebServerProfile \
  --role-name WebServerRole
```

### Step 3: Create Launch Template

```bash
# Get the latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

# Create a key pair for SSH access
aws ec2 create-key-pair \
  --key-name web-server-key \
  --query 'KeyMaterial' --output text > web-server-key.pem
chmod 400 web-server-key.pem

# Encode the user-data bootstrap script
USER_DATA=$(base64 -w 0 scripts/user-data.sh)

# Create the launch template
aws ec2 create-launch-template \
  --launch-template-name WebServerTemplate \
  --version-description "v1" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"t3.micro\",
    \"KeyName\": \"web-server-key\",
    \"SecurityGroupIds\": [\"$EC2_SG\"],
    \"IamInstanceProfile\": {\"Name\": \"WebServerProfile\"},
    \"UserData\": \"$USER_DATA\",
    \"Monitoring\": {\"Enabled\": true},
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"WebServer-ASG\"}]
    }]
  }"
```

### Step 4: Create Application Load Balancer

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name web-tier-alb \
  --subnets $PUB_SUBNET_1 $PUB_SUBNET_2 \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

TG_ARN=$(aws elbv2 create-target-group \
  --name web-servers-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB DNS: $ALB_DNS"
```

### Step 5: Create Auto Scaling Group

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name web-tier-asg \
  --launch-template LaunchTemplateName=WebServerTemplate,Version='$Latest' \
  --min-size 2 \
  --max-size 10 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$PUB_SUBNET_1,$PUB_SUBNET_2" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --tags \
    Key=Name,Value=WebServer-ASG,PropagateAtLaunch=true \
    Key=Environment,Value=Production,PropagateAtLaunch=true
```

### Step 6: Configure Scaling Policies

#### Target Tracking (Recommended)

```bash
# Scale to maintain 60% average CPU utilization
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name web-tier-asg \
  --policy-name cpu-target-tracking \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 60.0,
    "ScaleInCooldown": 300,
    "ScaleOutCooldown": 60
  }'
```

#### Step Scaling (Advanced)

```bash
# Scale-out policy: +1 instance for CPU 70-90%, +2 for CPU > 90%
SCALE_OUT_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name web-tier-asg \
  --policy-name scale-out-policy \
  --policy-type StepScaling \
  --adjustment-type ChangeInCapacity \
  --step-adjustments \
    MetricIntervalLowerBound=0,MetricIntervalUpperBound=20,ScalingAdjustment=1 \
    MetricIntervalLowerBound=20,ScalingAdjustment=2 \
  --query 'PolicyARN' --output text)

# Scale-in policy: -1 instance when CPU drops below threshold
SCALE_IN_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name web-tier-asg \
  --policy-name scale-in-policy \
  --policy-type StepScaling \
  --adjustment-type ChangeInCapacity \
  --step-adjustments MetricIntervalUpperBound=0,ScalingAdjustment=-1 \
  --query 'PolicyARN' --output text)

# CloudWatch alarms to trigger the step policies
aws cloudwatch put-metric-alarm \
  --alarm-name asg-scale-out \
  --alarm-description "Scale out when CPU > 70%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --dimensions Name=AutoScalingGroupName,Value=web-tier-asg \
  --statistic Average \
  --period 120 \
  --evaluation-periods 2 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --alarm-actions $SCALE_OUT_ARN

aws cloudwatch put-metric-alarm \
  --alarm-name asg-scale-in \
  --alarm-description "Scale in when CPU < 30%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --dimensions Name=AutoScalingGroupName,Value=web-tier-asg \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --alarm-actions $SCALE_IN_ARN
```

#### Scheduled Scaling

```bash
# Scale up on weekday mornings
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name web-tier-asg \
  --scheduled-action-name scale-up-morning \
  --recurrence "0 8 * * MON-FRI" \
  --min-size 4 --max-size 10 --desired-capacity 4

# Scale down weekday nights
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name web-tier-asg \
  --scheduled-action-name scale-down-night \
  --recurrence "0 20 * * MON-FRI" \
  --min-size 2 --max-size 10 --desired-capacity 2
```

### Step 7: Configure Instance Refresh

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name web-tier-asg \
  --preferences '{
    "MinHealthyPercentage": 90,
    "InstanceWarmup": 300
  }'

aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name web-tier-asg
```

## Console Deployment

### 1. Create Security Groups

1. Go to **EC2 → Security Groups → Create security group**
   - **Name:** `alb-sg` | **VPC:** your VPC
   - **Inbound:** HTTP port 80, HTTPS port 443, Source: `0.0.0.0/0` → **Create**
2. Create a second security group:
   - **Name:** `ec2-web-sg` | **VPC:** your VPC
   - **Inbound:** HTTP port 80, Source: `alb-sg`
   - **Inbound:** SSH port 22, Source: My IP → **Create**

### 2. Create IAM Role for EC2

1. Go to **IAM → Roles → Create role** → AWS service → EC2 → **Next**
2. Attach **CloudWatchAgentServerPolicy** and **AmazonSSMManagedInstanceCore** → **Next**
3. **Role name:** `WebServerRole` → **Create role**

### 3. Create Key Pair

1. Go to **EC2 → Key Pairs → Create key pair**
   - **Name:** `web-server-key` | RSA | .pem → download and save securely

### 4. Create Launch Template

1. Go to **EC2 → Launch Templates → Create launch template**
   - **Name:** `WebServerTemplate` | **Version description:** v1
   - **AMI:** search for `Amazon Linux 2023`, select the latest
   - **Instance type:** `t3.micro`
   - **Key pair:** `web-server-key`
   - **Security groups:** `ec2-web-sg`
   - **IAM instance profile:** `WebServerRole`
   - **Advanced details → User data:** paste the contents of `scripts/user-data.sh`
2. Click **Create launch template**

### 5. Create Target Group

1. Go to **EC2 → Target Groups → Create target group**
   - **Target type:** Instances | **Name:** `web-servers-tg` | **Protocol:** HTTP | **Port:** 80 | **VPC:** your VPC
   - **Health check path:** `/health` | **Healthy threshold:** 2 | **Unhealthy threshold:** 3
2. Click **Create target group**

### 6. Create Application Load Balancer

1. Go to **EC2 → Load Balancers → Create load balancer → Application Load Balancer**
   - **Name:** `web-tier-alb` | **Scheme:** Internet-facing | **IP type:** IPv4
   - **Subnets:** select at least 2 public subnets in different AZs
   - **Security group:** `alb-sg`
   - **Listener:** HTTP:80 → forward to `web-servers-tg`
2. Click **Create load balancer** — copy the DNS name when ready

### 7. Create Auto Scaling Group

1. Go to **EC2 → Auto Scaling Groups → Create Auto Scaling group**
   - **Name:** `web-tier-asg`
   - **Launch template:** `WebServerTemplate` (latest version) → **Next**
   - **VPC:** your VPC | **Availability Zones/Subnets:** select 2+ public subnets → **Next**
   - **Load balancing:** attach to `web-servers-tg` | **Health check:** ELB | **Grace period:** 300s → **Next**
   - **Group size:** Desired: 2 | Min: 2 | Max: 10 → **Next**
2. Click through remaining steps → **Create Auto Scaling group**

### 8. Configure Scaling Policies

1. Open `web-tier-asg` → **Automatic scaling → Create dynamic scaling policy**
2. **Policy type:** Target tracking
   - **Metric:** Average CPU utilization | **Target value:** 60 → **Create**
3. For scheduled scaling: **Scheduled actions → Create scheduled action**
   - Scale-up: Desired 4, Recurrence `0 8 * * MON-FRI`
   - Scale-down: Desired 2, Recurrence `0 20 * * MON-FRI`

### Console Cleanup

1. **EC2 → Auto Scaling Groups** → delete `web-tier-asg`
2. **EC2 → Load Balancers** → delete `web-tier-alb`
3. **EC2 → Target Groups** → delete `web-servers-tg`
4. **EC2 → Launch Templates** → delete `WebServerTemplate`
5. **EC2 → Security Groups** → delete `ec2-web-sg` then `alb-sg`
6. **EC2 → Key Pairs** → delete `web-server-key`
7. **IAM → Roles** → delete `WebServerRole`

---

## CLI Automation

The `scripts/create-asg.sh` script automates steps 3 and 5. Export the required variables before running it:

```bash
export VPC_ID="vpc-xxxx"
export PUB_SUBNET_1="subnet-xxxx"
export PUB_SUBNET_2="subnet-yyyy"
export EC2_SG="sg-xxxx"
export WEB_SERVER_PROFILE="WebServerProfile"

bash scripts/create-asg.sh
```

## Testing and Validation

```bash
# Verify the ALB returns a healthy response
curl -s http://$ALB_DNS/health

# Check current ASG state
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names web-tier-asg \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:length(Instances)}'

# Run a simple load test (requires httpd-tools)
sudo yum install httpd-tools -y
ab -n 10000 -c 100 http://$ALB_DNS/

# Watch scaling activity in real time
watch -n 5 'aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name web-tier-asg --max-items 5'

# Test self-healing: terminate an instance and watch ASG replace it
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names web-tier-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
```

## Cleanup

```bash
# Delete ASG (force-delete removes instances)
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name web-tier-asg \
  --force-delete

# Delete ALB and target group (wait ~30s after deleting ALB before target group)
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
sleep 30
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# Delete launch template
aws ec2 delete-launch-template --launch-template-name WebServerTemplate

# Delete CloudWatch alarms and dashboard
aws cloudwatch delete-alarms --alarm-names asg-scale-out asg-scale-in
aws cloudwatch delete-dashboards --dashboard-names WebTierDashboard

# Delete IAM resources
aws iam remove-role-from-instance-profile \
  --instance-profile-name WebServerProfile --role-name WebServerRole
aws iam delete-instance-profile --instance-profile-name WebServerProfile
aws iam detach-role-policy --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam detach-role-policy --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name WebServerRole

# Delete networking resources
aws ec2 delete-security-group --group-id $EC2_SG
aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 delete-key-pair --key-name web-server-key
rm -f web-server-key.pem
```

## Learning Objectives

After completing this project you will understand:

- Creating and configuring Application Load Balancers with target groups
- Writing EC2 launch templates with user-data bootstrap scripts
- Building Auto Scaling Groups with minimum, maximum, and desired capacity
- Implementing target tracking scaling policies for CPU utilization
- Using step scaling and CloudWatch alarms for granular control
- Scheduling predictable capacity changes with scheduled scaling actions
- Performing zero-downtime rolling updates with instance refresh
- Testing self-healing behaviour by terminating instances
- Monitoring scaling activity through CloudWatch and ASG activity history
