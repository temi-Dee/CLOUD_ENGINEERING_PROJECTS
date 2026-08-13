#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)

if [ -z "${VPC_ID:-}" ] || [ -z "${PUB_SUBNET_1:-}" ] || [ -z "${PUB_SUBNET_2:-}" ] || \
   [ -z "${EC2_SG:-}" ] || [ -z "${WEB_SERVER_PROFILE:-}" ]; then
  echo "Required environment variables not set."
  echo "Please export: VPC_ID, PUB_SUBNET_1, PUB_SUBNET_2, EC2_SG, WEB_SERVER_PROFILE"
  exit 1
fi

# Resolve the script directory so user-data.sh is found regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

echo "Using AMI: $AMI_ID"

# Create the launch template
aws ec2 create-launch-template \
  --launch-template-name WebServerTemplate \
  --version-description "v1" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"t3.micro\",
    \"KeyName\": \"web-server-key\",
    \"SecurityGroupIds\": [\"$EC2_SG\"],
    \"IamInstanceProfile\": {\"Name\": \"$WEB_SERVER_PROFILE\"},
    \"UserData\": \"$(base64 -w 0 "$SCRIPT_DIR/user-data.sh")\",
    \"Monitoring\": {\"Enabled\": true},
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"WebServer-ASG\"}]
    }]
  }"

echo "Launch template created: WebServerTemplate"

# Create the Auto Scaling Group
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name web-tier-asg \
  --launch-template LaunchTemplateName=WebServerTemplate,Version='$Latest' \
  --min-size 2 \
  --max-size 10 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$PUB_SUBNET_1,$PUB_SUBNET_2" \
  --health-check-type EC2 \
  --health-check-grace-period 300 \
  --tags \
    Key=Name,Value=WebServer-ASG,PropagateAtLaunch=true \
    Key=Environment,Value=Production,PropagateAtLaunch=true

echo "Auto Scaling Group created: web-tier-asg"
echo "Next: attach a target group with 'aws autoscaling attach-load-balancer-target-groups'"
