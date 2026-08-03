#!/bin/bash
# Project 2: Cleanup Script

set -e

echo "🧹 Starting cleanup..."

# Read instance info
if [ -f instance-info.txt ]; then
    INSTANCE_ID=$(grep "Instance ID:" instance-info.txt | cut -d' ' -f3)
    SG_ID=$(grep "Security Group:" instance-info.txt | cut -d' ' -f3)
fi

# Terminate instance
if [ ! -z "$INSTANCE_ID" ]; then
    echo "Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
    echo "✓ Instance terminated"
fi

# Delete security group
if [ ! -z "$SG_ID" ]; then
    echo "Deleting security group..."
    sleep 10
    aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || echo "Security group already deleted"
    echo "✓ Security group deleted"
fi

# Delete key pair
echo "Deleting key pair..."
aws ec2 delete-key-pair --key-name web-server-key 2>/dev/null || true
rm -f web-server-key.pem
echo "✓ Key pair deleted"

# Delete IAM resources
echo "Deleting IAM resources..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name WebServerProfile \
  --role-name WebServerRole 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name WebServerProfile 2>/dev/null || true
aws iam detach-role-policy \
  --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
aws iam delete-role --role-name WebServerRole 2>/dev/null || true
echo "✓ IAM resources deleted"

# Clean up local files
rm -f ec2-trust-policy.json user-data.sh instance-info.txt

echo ""
echo "✅ Cleanup complete!"
