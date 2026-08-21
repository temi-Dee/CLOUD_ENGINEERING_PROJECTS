# Project 15: Blue/Green and Canary Deployments

## Overview

Deploying application updates without downtime is critical for maintaining service availability. Traditional rolling deployments can cause brief inconsistencies. You want deployment strategies that allow safe, reversible updates with minimal risk. In this project you will implement both blue/green and canary deployment patterns using AWS CodeDeploy with ECS Fargate, ALB weighted target groups for canary traffic shifting, and automated rollback triggered by CloudWatch alarms.

## Prerequisites

- An AWS account with CodeDeploy, ECS, ECR, ALB, IAM, and CloudWatch permissions
- AWS CLI configured with credentials (`aws configure`)
- A running ECS cluster (`my-app-cluster`) and an Application Load Balancer
- Docker installed for building and pushing images
- Basic understanding of blue/green and canary deployment patterns

## Project Structure

```
AWS Project 15 - Blue-Green Canary Deployments/
├── README.md
├── task-def.json              # ECS Fargate task definition template
├── appspec.yaml               # CodeDeploy AppSpec for ECS blue/green deployment
└── validate-deployment.js     # Lambda function for CodeDeploy lifecycle hook validation
```

## Architecture

```
Part A — Blue/Green (CodeDeploy + ECS)
  ALB Prod Listener (port 80)  --> Blue Target Group  (current stable)
  ALB Test Listener (port 8080) --> Green Target Group (new version)
  CodeDeploy swaps listeners atomically, then tears down the old environment.

Part B — Canary (ALB Weighted Routing)
  ALB Prod Listener --> [95% Stable TG | 5% Canary TG]
  Script gradually shifts weight (5 -> 10 -> 25 -> 50 -> 75 -> 100%)
  and rolls back automatically if error rate exceeds threshold.
```

## Part A: Blue/Green Deployment with ECS and CodeDeploy

### Step 1: Create Infrastructure (VPC, ALB, Target Groups, ECS)

```bash
# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

# Create blue and green target groups
BLUE_TG=$(aws elbv2 create-target-group \
  --name blue-tg \
  --protocol HTTP --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

GREEN_TG=$(aws elbv2 create-target-group \
  --name green-tg \
  --protocol HTTP --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "Blue TG:  $BLUE_TG"
echo "Green TG: $GREEN_TG"

# Create ALB (assumes public subnets exist — adjust subnet IDs as needed)
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ' ')

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name my-app-alb \
  --subnets $SUBNET_IDS \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Production listener (port 80) routes to blue
PROD_LISTENER=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$BLUE_TG \
  --query 'Listeners[0].ListenerArn' --output text)

# Test listener (port 8080) routes to green — used by CodeDeploy for validation
TEST_LISTENER=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$GREEN_TG \
  --query 'Listeners[0].ListenerArn' --output text)
```

### Step 2: Register the ECS Task Definition

The task definition template is in `task-def.json`. Replace `REPLACE_WITH_ECR_IMAGE` with your ECR image URI before registering.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

# Create ECR repository if it does not exist
aws ecr create-repository --repository-name my-app --region $REGION

# Build, tag, and push your Docker image
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

docker build -t my-app:blue .
docker tag my-app:blue $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:blue
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:blue

# Substitute the image URI and register
sed "s|REPLACE_WITH_ECR_IMAGE|$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:blue|" \
  task-def.json | aws ecs register-task-definition --cli-input-json file:///dev/stdin

# Create ECS security group
ECS_SG=$(aws ec2 create-security-group \
  --group-name ecs-bg-sg \
  --description "ECS Blue/Green SG" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG --protocol tcp --port 80 --cidr 0.0.0.0/0

# Create ECS service with CODE_DEPLOY controller
aws ecs create-service \
  --cluster my-app-cluster \
  --service-name my-app-service \
  --task-definition my-app \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$ECS_SG],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$BLUE_TG,containerName=app,containerPort=80" \
  --deployment-controller type=CODE_DEPLOY \
  --health-check-grace-period-seconds 60
```

### Step 3: Create CodeDeploy Application and Deployment Group

```bash
# Create IAM role for CodeDeploy
cat > codedeploy-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codedeploy.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name CodeDeployECSRole \
  --assume-role-policy-document file://codedeploy-trust-policy.json

aws iam attach-role-policy \
  --role-name CodeDeployECSRole \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS

CODEDEPLOY_ROLE=$(aws iam get-role \
  --role-name CodeDeployECSRole \
  --query 'Role.Arn' --output text)

# Create CodeDeploy application
aws deploy create-application \
  --application-name my-app \
  --compute-platform ECS

# Create deployment group wired to the ALB listeners and target groups
aws deploy create-deployment-group \
  --application-name my-app \
  --deployment-group-name my-app-dg \
  --service-role-arn $CODEDEPLOY_ROLE \
  --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
  --ecs-services clusterName=my-app-cluster,serviceName=my-app-service \
  --load-balancer-info "{
    \"targetGroupPairInfoList\": [{
      \"targetGroups\": [
        {\"name\": \"blue-tg\"},
        {\"name\": \"green-tg\"}
      ],
      \"prodTrafficRoute\": {\"listenerArns\": [\"$PROD_LISTENER\"]},
      \"testTrafficRoute\": {\"listenerArns\": [\"$TEST_LISTENER\"]}
    }]
  }" \
  --auto-rollback-configuration "enabled=true,events=DEPLOYMENT_FAILURE,DEPLOYMENT_STOP_ON_ALARM" \
  --alarm-configuration "enabled=true,alarms=[{\"name\":\"high-error-rate\"}]"
```

### Step 4: Deploy the Validation Lambda Hook

`validate-deployment.js` is the Lambda function used for CodeDeploy lifecycle hooks. It calls the test listener health endpoint and reports success or failure back to CodeDeploy via `putLifecycleEventHookExecutionStatus`.

```bash
# Package and deploy the validation Lambda
zip validate-deployment.zip validate-deployment.js

# Create Lambda execution role
cat > lambda-trust.json << 'EOF'
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
  --role-name ValidateLambdaRole \
  --assume-role-policy-document file://lambda-trust.json

aws iam attach-role-policy \
  --role-name ValidateLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > codedeploy-hook-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "codedeploy:PutLifecycleEventHookExecutionStatus",
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name ValidateLambdaRole \
  --policy-name CodeDeployHookPolicy \
  --policy-document file://codedeploy-hook-policy.json

VALIDATE_ROLE=$(aws iam get-role \
  --role-name ValidateLambdaRole \
  --query 'Role.Arn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

aws lambda create-function \
  --function-name ValidateTestTraffic \
  --runtime nodejs18.x \
  --role $VALIDATE_ROLE \
  --handler validate-deployment.handler \
  --zip-file fileb://validate-deployment.zip \
  --timeout 60 \
  --environment Variables="{ALB_DNS=$ALB_DNS}"
```

### Step 5: Trigger a Blue/Green Deployment

```bash
# Build and push the green (new) image
docker build -t my-app:green .
docker tag my-app:green $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:green
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:green

# Register the new task definition
NEW_TASK_DEF=$(aws ecs register-task-definition \
  --family my-app \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --container-definitions "[{
    \"name\": \"app\",
    \"image\": \"$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/my-app:green\",
    \"portMappings\": [{\"containerPort\": 80, \"protocol\": \"tcp\"}],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"/ecs/my-app\",
        \"awslogs-region\": \"$REGION\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

TASK_DEF_REVISION=$(echo $NEW_TASK_DEF | grep -oP ':\K[0-9]+$')

# Update appspec.yaml with the new task definition ARN
sed "s|REPLACE_WITH_TASK_DEFINITION_ARN|$NEW_TASK_DEF|" appspec.yaml > appspec-deploy.yaml

# Create the CodeDeploy deployment
aws deploy create-deployment \
  --application-name my-app \
  --deployment-group-name my-app-dg \
  --revision "revisionType=AppSpecContent,appSpecContent={content=\"$(cat appspec-deploy.yaml | base64 -w 0)\"}"
```

## Part B: Canary Deployment with ALB Weighted Target Groups

### Step 1: Create the Canary Target Group and Start Routing

```bash
CANARY_TG=$(aws elbv2 create-target-group \
  --name canary-tg \
  --protocol HTTP --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Start at 5% canary, 95% stable
aws elbv2 modify-listener \
  --listener-arn $PROD_LISTENER \
  --default-actions "[{
    \"Type\": \"forward\",
    \"ForwardConfig\": {
      \"TargetGroups\": [
        {\"TargetGroupArn\": \"$BLUE_TG\", \"Weight\": 95},
        {\"TargetGroupArn\": \"$CANARY_TG\", \"Weight\": 5}
      ],
      \"StickinessConfig\": {
        \"Enabled\": true,
        \"DurationSeconds\": 300
      }
    }
  }]"
```

### Step 2: Run the Automated Canary Progression Script

```bash
cat > canary-deploy.sh << 'SCRIPT'
#!/bin/bash
set -e

PROD_TG=$1
CANARY_TG=$2
LISTENER_ARN=$3
ERROR_THRESHOLD=1   # Max 1% error rate before rollback

WEIGHTS=(5 10 25 50 75 100)

for WEIGHT in "${WEIGHTS[@]}"; do
    PROD_WEIGHT=$((100 - WEIGHT))

    echo "Shifting $WEIGHT% traffic to canary..."

    aws elbv2 modify-listener \
      --listener-arn $LISTENER_ARN \
      --default-actions "[{
        \"Type\": \"forward\",
        \"ForwardConfig\": {
          \"TargetGroups\": [
            {\"TargetGroupArn\": \"$PROD_TG\", \"Weight\": $PROD_WEIGHT},
            {\"TargetGroupArn\": \"$CANARY_TG\", \"Weight\": $WEIGHT}
          ]
        }
      }]"

    echo "Waiting 5 minutes to observe metrics..."
    sleep 300

    # Check canary error rate
    TG_SUFFIX=$(echo $CANARY_TG | cut -d: -f6)
    ERROR_COUNT=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/ApplicationELB \
      --metric-name HTTPCode_Target_5XX_Count \
      --dimensions Name=TargetGroup,Value=$TG_SUFFIX \
      --start-time $(date -u -d '5 minutes ago' --iso-8601) \
      --end-time $(date -u --iso-8601) \
      --period 300 --statistics Sum \
      --query 'Datapoints[0].Sum' --output text)

    TOTAL=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/ApplicationELB \
      --metric-name RequestCount \
      --dimensions Name=TargetGroup,Value=$TG_SUFFIX \
      --start-time $(date -u -d '5 minutes ago' --iso-8601) \
      --end-time $(date -u --iso-8601) \
      --period 300 --statistics Sum \
      --query 'Datapoints[0].Sum' --output text)

    if [ "$TOTAL" != "None" ] && [ "${TOTAL%.*}" -gt 0 ]; then
        CURRENT_ERROR_RATE=$(echo "scale=2; ${ERROR_COUNT:-0} / $TOTAL * 100" | bc)
        echo "Current error rate: $CURRENT_ERROR_RATE%"

        if (( $(echo "$CURRENT_ERROR_RATE > $ERROR_THRESHOLD" | bc -l) )); then
            echo "ERROR: Error rate $CURRENT_ERROR_RATE% exceeds threshold $ERROR_THRESHOLD%"
            echo "Rolling back to 100% production traffic..."

            aws elbv2 modify-listener \
              --listener-arn $LISTENER_ARN \
              --default-actions "[{
                \"Type\": \"forward\",
                \"TargetGroupArn\": \"$PROD_TG\"
              }]"

            exit 1
        fi
    fi

    echo "Canary healthy at $WEIGHT% traffic"
done

echo "Canary deployment complete — 100% traffic on new version."
SCRIPT

chmod +x canary-deploy.sh
./canary-deploy.sh $BLUE_TG $CANARY_TG $PROD_LISTENER
```

### Step 3: Create CodeDeploy Canary and Linear Deployment Configs

```bash
# Canary: 10% for 5 minutes, then 100%
aws deploy create-deployment-config \
  --deployment-config-name ECSCanary10Percent5Minutes \
  --compute-platform ECS \
  --traffic-routing-config "{
    \"type\": \"TimeBasedCanary\",
    \"timeBasedCanary\": {
      \"canaryPercentage\": 10,
      \"canaryInterval\": 5
    }
  }"

# Linear: increment 10% every minute
aws deploy create-deployment-config \
  --deployment-config-name ECSLinear10PercentEvery1Minute \
  --compute-platform ECS \
  --traffic-routing-config "{
    \"type\": \"TimeBasedLinear\",
    \"timeBasedLinear\": {
      \"linearPercentage\": 10,
      \"linearInterval\": 1
    }
  }"
```

## Console Deployment

### Part A: Blue/Green with CodeDeploy

#### 1. Create Target Groups

1. Go to **EC2 → Target Groups → Create target group**
   - **Type:** IP | **Name:** `blue-tg` | **Protocol:** HTTP | **Port:** 80 | **VPC:** default
   - **Health check path:** `/health` → **Create**
2. Repeat: **Name:** `green-tg` (same settings)

#### 2. Create Application Load Balancer

1. Go to **EC2 → Load Balancers → Create load balancer → Application Load Balancer**
   - **Name:** `my-app-alb` | **Scheme:** Internet-facing | select 2+ public subnets
2. Create a security group allowing HTTP port 80 and port 8080 → attach it
3. **Listener HTTP:80** → default action: forward to `blue-tg`
4. After creation, **Add listener HTTP:8080** → forward to `green-tg` (used by CodeDeploy for validation)

#### 3. Create ECS Task Execution Role

1. Go to **IAM → Roles → Create role** → ECS Task → attach **AmazonECSTaskExecutionRolePolicy** → **Name:** `ecsTaskExecutionRole` → **Create**

#### 4. Create ECS Task Definition

1. Go to **ECS → Task definitions → Create new task definition**
   - **Family:** `my-app` | **Launch type:** Fargate | **CPU:** 0.25 | **Memory:** 0.5 GB
   - **Container:** name: `app` | image: your ECR URI | port: 80
2. Click **Create**

#### 5. Create ECS Service with CodeDeploy Controller

1. Go to **ECS → my-app-cluster → Create service**
   - **Launch type:** Fargate | **Task definition:** `my-app` | **Service name:** `my-app-service` | **Desired tasks:** 2
   - **Deployment type:** Blue/green (CodeDeploy)
   - **Load balancer:** `my-app-alb` | **Production listener:** 80 | **Test listener:** 8080
   - **Blue target group:** `blue-tg` | **Green target group:** `green-tg`
2. Click **Create service**

#### 6. Create CodeDeploy IAM Role

1. Go to **IAM → Roles → Create role** → AWS service → **CodeDeploy → ECS** → attach **AWSCodeDeployRoleForECS** → **Name:** `CodeDeployECSRole` → **Create**

#### 7. Create CodeDeploy Application and Deployment Group

1. Go to **CodeDeploy → Applications → Create application**
   - **Name:** `my-app` | **Compute platform:** Amazon ECS → **Create**
2. Click **Create deployment group**
   - **Name:** `my-app-dg` | **Service role:** `CodeDeployECSRole`
   - **ECS cluster:** `my-app-cluster` | **ECS service:** `my-app-service`
   - **Load balancer:** `my-app-alb` | **Prod listener:** port 80 | **Test listener:** port 8080
   - **Blue TG:** `blue-tg` | **Green TG:** `green-tg`
   - **Deployment config:** `CodeDeployDefault.ECSAllAtOnce`
   - **Rollback:** enable on deployment failure → **Create**

#### 8. Trigger a Blue/Green Deployment

1. Go to **CodeDeploy → Applications → my-app → Create deployment**
2. **Deployment group:** `my-app-dg` | **Revision type:** AppSpec content
3. Paste your `appspec.yaml` content with the new task definition ARN → **Create deployment**
4. Monitor progress — CodeDeploy will route test traffic, validate, then shift production

### Part B: Canary via ALB Weighted Routing

1. Go to **EC2 → Target Groups → Create target group** → **Name:** `canary-tg` | same settings as above
2. Go to **EC2 → Load Balancers → my-app-alb → Listeners → HTTP:80 → Edit rules**
3. Edit the default rule → change action to **Forward to multiple target groups**
   - `blue-tg`: weight 95 | `canary-tg`: weight 5 → **Save changes**
4. After monitoring canary health in CloudWatch, gradually increase `canary-tg` weight (10 → 25 → 50 → 100%)
5. If metrics look bad, revert to `blue-tg` weight 100 immediately

### Console Cleanup

1. **CodeDeploy** → delete deployment group → delete application
2. **ECS** → update `my-app-service` to 0 desired → delete service
3. **EC2 → Load Balancers** → delete `my-app-alb` (delete listeners first)
4. **EC2 → Target Groups** → delete `blue-tg`, `green-tg`, `canary-tg`
5. **Lambda** → delete `ValidateTestTraffic`
6. **IAM → Roles** → delete `CodeDeployECSRole` and `ValidateLambdaRole`

---

## CLI / Automation Reference

```bash
# Watch deployment status every 10 seconds (replace d-XXXXXXXXX with real ID)
watch -n 10 'aws deploy get-deployment \
  --deployment-id d-XXXXXXXXX \
  --query "deploymentInfo.{Status:status,Succeeded:deploymentOverview.Succeeded,Failed:deploymentOverview.Failed}"'

# View deployment history
aws deploy list-deployments \
  --application-name my-app \
  --deployment-group-name my-app-dg \
  --include-only-statuses Succeeded Failed

# Manually stop and roll back a deployment
aws deploy stop-deployment \
  --deployment-id d-XXXXXXXXX \
  --auto-rollback-enabled
```

## Deployment Strategies Comparison

| Strategy   | Traffic Shift  | Rollback Speed | Risk     |
|------------|---------------|----------------|----------|
| Blue-Green | Instant       | Instant        | Low      |
| Canary     | Gradual %     | Fast           | Very Low |
| Rolling    | Gradual pods  | Slow           | Medium   |

## Cleanup

```bash
# Delete CodeDeploy resources
aws deploy delete-deployment-group \
  --application-name my-app \
  --deployment-group-name my-app-dg
aws deploy delete-application --application-name my-app

# Stop ECS service
aws ecs update-service \
  --cluster my-app-cluster \
  --service my-app-service \
  --desired-count 0
aws ecs delete-service \
  --cluster my-app-cluster \
  --service my-app-service

# Delete ALB listeners and target groups
aws elbv2 delete-listener --listener-arn $PROD_LISTENER
aws elbv2 delete-listener --listener-arn $TEST_LISTENER
aws elbv2 delete-target-group --target-group-arn $BLUE_TG
aws elbv2 delete-target-group --target-group-arn $GREEN_TG
aws elbv2 delete-target-group --target-group-arn $CANARY_TG
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN

# Delete Lambda and its IAM role
aws lambda delete-function --function-name ValidateTestTraffic
aws iam delete-role-policy --role-name ValidateLambdaRole --policy-name CodeDeployHookPolicy
aws iam detach-role-policy --role-name ValidateLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ValidateLambdaRole

# Delete CodeDeploy IAM role
aws iam detach-role-policy --role-name CodeDeployECSRole \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS
aws iam delete-role --role-name CodeDeployECSRole
```

## Testing / Validation

1. After creating the ECS service, run `aws ecs describe-services --cluster my-app-cluster --services my-app-service` and confirm `runningCount` equals `desiredCount`.
2. Trigger a blue/green deployment and confirm the test listener on port 8080 responds before CodeDeploy cuts over production traffic.
3. Run the canary script with a deliberately broken image and confirm it rolls back automatically when the error rate threshold is exceeded.
4. Check CloudWatch `HTTPCode_Target_5XX_Count` for each target group to validate traffic weighting is working.

## Learning Objectives

After completing this project, you will understand:

- Blue/green deployment mechanics: parallel environments with instant traffic cutover
- Canary deployment mechanics: gradual traffic shifting with metric-driven rollback
- CodeDeploy for ECS: deployment groups, AppSpec, lifecycle hooks, and deployment configs
- ALB weighted target groups for fine-grained traffic control
- Lambda lifecycle hooks for automated pre-flight validation
- Automated rollback based on CloudWatch alarm thresholds
- Deployment configuration options: AllAtOnce, Canary, and Linear

## Troubleshooting

- **Deployment stuck in "Replacement tasks not started"**: Check ECS service events and task launch failures
- **Health checks failing**: Verify the `/health` endpoint is implemented and the health check grace period is sufficient
- **Rollback not triggering**: Confirm the CloudWatch alarm is in `ALARM` state and is linked to the deployment group
- **Traffic not shifting**: Check that the ALB listener rules reference the correct target group ARNs
