# Project 19: Chaos Engineering and Game Days

## Overview

Systems fail. Networks lag. Servers crash. Instead of hoping your application survives these failures, chaos engineering lets you deliberately inject faults to uncover weaknesses before customers do. In this project you will implement a comprehensive chaos engineering program using AWS Fault Injection Simulator (FIS) for AWS-native experiments, Chaos Mesh for Kubernetes-native fault injection, and a steady-state monitor Lambda that automatically halts experiments when key metrics degrade.

## Prerequisites

- AWS account with FIS permissions enabled
- Running EC2 instances or ECS cluster tagged with `ChaosEnabled: "true"`
- Running EKS cluster with Chaos Mesh installed (Step 5)
- CloudWatch alarms configured for `high-error-rate` and `high-latency`
- Application logging and monitoring in place
- Incident response runbooks documented before running any experiments

## Project Structure

```
AWS Project 19 - Chaos Engineering/
├── README.md
├── fis-trust-policy.json           # IAM trust policy for the FIS experiment role
├── cpu-stress-experiment.json      # FIS template: CPU stress on EC2 instances
├── ecs-chaos.json                  # FIS template: stop random ECS tasks
├── pod-kill-chaos.yaml             # Chaos Mesh: kill one production web-server pod on schedule
├── network-delay.yaml              # Chaos Mesh: inject 200ms latency on all api-server pods
└── steady-state-monitor.py        # Lambda: monitors ALB latency and stops running FIS experiments
```

## Steps

### Step 1: Create the FIS IAM Role

```bash
aws iam create-role \
  --role-name FISExperimentRole \
  --assume-role-policy-document file://fis-trust-policy.json

aws iam attach-role-policy \
  --role-name FISExperimentRole \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

FIS_ROLE_ARN=$(aws iam get-role \
  --role-name FISExperimentRole \
  --query 'Role.Arn' \
  --output text)
```

### Step 2: Prepare CloudWatch Stop-Condition Alarms

Before creating experiment templates, ensure these alarms exist. FIS will automatically stop an experiment if any stop-condition alarm enters ALARM state.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name high-error-rate \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold

aws cloudwatch put-metric-alarm \
  --alarm-name high-latency \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 2 \
  --comparison-operator GreaterThanThreshold
```

### Step 3: Create the CPU Stress FIS Experiment

Substitute `ACCOUNT_ID` in the template file, then create the experiment template:

```bash
sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" cpu-stress-experiment.json > /tmp/cpu-stress-applied.json

CPU_EXPERIMENT_ID=$(aws fis create-experiment-template \
  --cli-input-json file:///tmp/cpu-stress-applied.json \
  --query 'experimentTemplate.id' \
  --output text)

echo "CPU stress experiment template ID: $CPU_EXPERIMENT_ID"
```

### Step 4: Create the ECS Task-Stop FIS Experiment

```bash
sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" ecs-chaos.json > /tmp/ecs-chaos-applied.json

ECS_EXPERIMENT_ID=$(aws fis create-experiment-template \
  --cli-input-json file:///tmp/ecs-chaos-applied.json \
  --query 'experimentTemplate.id' \
  --output text)

echo "ECS chaos experiment template ID: $ECS_EXPERIMENT_ID"
```

### Step 5: Install Chaos Mesh on EKS

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --set chaosDaemon.podAnnotations."prometheus\.io/scrape"="true"

# Verify installation
kubectl get pods -n chaos-mesh
kubectl get crd | grep chaos-mesh
```

### Step 6: Apply the Pod Kill Experiment

The `pod-kill-chaos.yaml` template kills one web-server pod in the `production` namespace daily at 02:00. Pods must carry the label `chaos: enabled` to be targeted.

```bash
kubectl apply -f pod-kill-chaos.yaml

# Verify the experiment was registered
kubectl get podchaos -n production
```

### Step 7: Apply the Network Delay Experiment

The `network-delay.yaml` template injects 200ms ± 20ms latency onto all pods labelled `component: api-server` in the `production` namespace for 10 minutes.

```bash
kubectl apply -f network-delay.yaml

# Verify
kubectl get networkchaos -n production
```

### Step 8: Deploy the Steady-State Monitor Lambda

The monitor reads `TargetResponseTime` from CloudWatch every minute and stops all running FIS experiments if average latency exceeds the configured threshold (default: 500ms = 0.5s).

```bash
# Package the function
zip monitor-function.zip steady-state-monitor.py

# Create an IAM role for the Lambda
cat > monitor-trust-policy.json << 'EOF'
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
  --role-name ChaosMonitorRole \
  --assume-role-policy-document file://monitor-trust-policy.json

aws iam attach-role-policy \
  --role-name ChaosMonitorRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > monitor-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "cloudwatch:GetMetricStatistics",
      "fis:ListExperiments",
      "fis:StopExperiment"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name ChaosMonitorRole \
  --policy-name ChaosMonitorPolicy \
  --policy-document file://monitor-policy.json

MONITOR_ROLE_ARN=$(aws iam get-role --role-name ChaosMonitorRole --query 'Role.Arn' --output text)

# Deploy Lambda (replace ALB_DIMENSION with your actual ALB suffix, e.g. app/my-alb/abc123)
aws lambda create-function \
  --function-name ChaosEngineeringMonitor \
  --runtime python3.11 \
  --role $MONITOR_ROLE_ARN \
  --handler steady-state-monitor.lambda_handler \
  --zip-file fileb://monitor-function.zip \
  --timeout 30 \
  --environment Variables="{ALB_DIMENSION=app/my-alb/abc123,LATENCY_THRESHOLD_SECONDS=0.5}"

# Schedule to run every minute
aws events put-rule \
  --name chaos-steady-state-monitor \
  --schedule-expression 'rate(1 minute)' \
  --state ENABLED

MONITOR_RULE_ARN=$(aws events describe-rule \
  --name chaos-steady-state-monitor --query 'Arn' --output text)
MONITOR_LAMBDA_ARN=$(aws lambda get-function \
  --function-name ChaosEngineeringMonitor \
  --query 'Configuration.FunctionArn' --output text)

aws events put-targets \
  --rule chaos-steady-state-monitor \
  --targets "Id=ChaosMonitor,Arn=$MONITOR_LAMBDA_ARN"

aws lambda add-permission \
  --function-name ChaosEngineeringMonitor \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn $MONITOR_RULE_ARN
```

## Console Deployment

### 1. Create FIS IAM Role

1. Go to **IAM → Roles → Create role** → AWS service → scroll down and select **Fault Injection Simulator** → **Next**
2. Attach **PowerUserAccess** (or a scoped policy for production) → **Next**
3. **Role name:** `FISExperimentRole` → **Create role**

### 2. Create Stop-Condition CloudWatch Alarms

1. Go to **CloudWatch → Alarms → Create alarm → Select metric → ApplicationELB → Per-LB Metrics**
2. Select your ALB → **HTTPCode_Target_5XX_Count** → **Select metric**
   - **Period:** 1 min | **Statistic:** Sum | **Threshold:** Greater than 50
   - **Alarm name:** `high-error-rate` → **Create alarm**
3. Repeat for **TargetResponseTime** > 2 seconds → **Alarm name:** `high-latency`

### 3. Create CPU Stress FIS Experiment

1. Go to **FIS → Experiment templates → Create experiment template**
2. **Description:** CPU stress on EC2 | **IAM role:** `FISExperimentRole`
3. **Actions → Add action**
   - **Name:** `cpu-stress` | **Action type:** `aws:ssm:send-command/AWSFIS-Run-CPU-Stress`
   - **Duration:** 5 minutes | **Workers:** 0 (all CPUs) | **Load:** 100
4. **Targets → Add target**
   - **Name:** `ec2-instances` | **Resource type:** `aws:ec2:instance`
   - **Selection mode:** All | **Filter:** tag `ChaosEnabled=true`
5. **Stop conditions:** add both `high-error-rate` and `high-latency` alarms
6. Click **Create experiment template**

### 4. Create ECS Task-Stop FIS Experiment

1. **FIS → Create experiment template**
2. **Action type:** `aws:ecs:stop-task`
   - **Cluster:** `my-app-cluster` | select target service | stop **1** random task
3. **Stop conditions:** `high-error-rate` and `high-latency`
4. Click **Create experiment template**

### 5. Create Steady-State Monitor Lambda

1. Go to **IAM → Roles → Create role** → Lambda → attach **AWSLambdaBasicExecutionRole** → **Name:** `ChaosMonitorRole`
2. Add inline policy:
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudwatch:GetMetricStatistics","fis:ListExperiments","fis:StopExperiment"],"Resource":"*"}]}
   ```
   **Policy name:** `ChaosMonitorPolicy`
3. Go to **Lambda → Create function** → **Name:** `ChaosEngineeringMonitor` | Python 3.11 | Role: `ChaosMonitorRole`
4. Paste `steady-state-monitor.py` → **Deploy**
5. **Configuration → Environment variables:** `ALB_DIMENSION` = your ALB suffix (e.g. `app/my-alb/abc123`) | `LATENCY_THRESHOLD_SECONDS` = `0.5`
6. Go to **EventBridge → Rules → Create rule** → **Schedule** → rate 1 minute → **Target:** `ChaosEngineeringMonitor` → **Create**

### 6. Run an Experiment

1. Go to **FIS → Experiment templates** → select your CPU stress template → **Start experiment**
2. Confirm by typing `start` → click **Start experiment**
3. Monitor the experiment state in FIS → go to **CloudWatch** to watch metrics in real time
4. FIS will stop automatically if a stop-condition alarm fires, or click **Stop experiment** to halt manually

### Console Cleanup

1. **FIS → Experiment templates** → delete CPU stress and ECS templates
2. **Lambda** → delete `ChaosEngineeringMonitor`
3. **EventBridge → Rules** → delete `chaos-steady-state-monitor`
4. **CloudWatch → Alarms** → delete `high-error-rate` and `high-latency`
5. **IAM → Roles** → delete `ChaosMonitorRole` and `FISExperimentRole`

---

## Architecture

```
[Hypothesis Definition]
         |
[FIS / Chaos Mesh] <----------> [Stop Conditions]
         |                           |
   [Inject Faults]           [CloudWatch Alarms]
         |                           |
   [Monitor Metrics] <------- [Steady-State Monitor Lambda]
         |
   [Analyze Results]
         |
   [Improve System]
```

## Testing and Validation

```bash
# Run the CPU stress experiment
EXPERIMENT_RUN=$(aws fis start-experiment \
  --experiment-template-id $CPU_EXPERIMENT_ID \
  --query 'experiment.id' \
  --output text)

# Monitor experiment state
aws fis get-experiment --id $EXPERIMENT_RUN \
  --query 'experiment.{State:state.status,Reason:state.reason}'

# Watch CloudWatch metrics while experiment runs
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average

# Stop experiment manually if needed
aws fis stop-experiment --id $EXPERIMENT_RUN
```

## Cleanup

```bash
# Delete FIS experiment templates
aws fis delete-experiment-template --id $CPU_EXPERIMENT_ID
aws fis delete-experiment-template --id $ECS_EXPERIMENT_ID

# Remove Chaos Mesh experiments
kubectl delete -f pod-kill-chaos.yaml
kubectl delete -f network-delay.yaml

# Remove Chaos Mesh
helm uninstall chaos-mesh -n chaos-mesh
kubectl delete namespace chaos-mesh

# Delete Lambda and EventBridge rule
aws events remove-targets --rule chaos-steady-state-monitor --ids ChaosMonitor
aws events delete-rule --name chaos-steady-state-monitor
aws lambda delete-function --function-name ChaosEngineeringMonitor

# Delete IAM roles
aws iam delete-role-policy --role-name ChaosMonitorRole --policy-name ChaosMonitorPolicy
aws iam detach-role-policy \
  --role-name ChaosMonitorRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ChaosMonitorRole

aws iam detach-role-policy \
  --role-name FISExperimentRole \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam delete-role --role-name FISExperimentRole
```

## Learning Objectives

After completing this project, you will understand:

- Chaos engineering principles and hypothesis-driven experiment design
- Steady-state definition and selecting meaningful SLO metrics
- AWS Fault Injection Simulator for EC2 and ECS fault injection
- Chaos Mesh for Kubernetes-native pod-kill and network-delay experiments
- Stop conditions and blast-radius management to prevent cascading failures
- Automated steady-state monitoring using Lambda and EventBridge
- Game-day planning: baseline measurement, fault injection, and post-analysis
- Building an organizational resilience culture through structured experimentation

## Troubleshooting

- **FIS experiment stuck in `initiating`**: Verify the target EC2/ECS resources carry the required tags (`ChaosEnabled: "true"`)
- **SSM send-command fails**: Ensure the SSM Agent is running on target instances and the FIS role has `ssm:SendCommand` permission
- **Chaos Mesh pods not starting**: Check that your EKS node group has sufficient permissions for the Chaos Mesh daemonset
- **Monitor Lambda not stopping experiments**: Confirm the `ALB_DIMENSION` env var matches the exact suffix shown in the CloudWatch console (e.g. `app/my-alb/abc123ef456`)
