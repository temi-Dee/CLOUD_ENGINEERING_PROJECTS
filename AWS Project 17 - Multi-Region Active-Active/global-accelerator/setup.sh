#!/bin/bash
set -e

PRIMARY_REGION="us-east-1"
SECONDARY_REGION="eu-west-1"

# Caller ALB ARNs must be supplied before running
: "${PRIMARY_ALB_ARN:?Set PRIMARY_ALB_ARN to the ARN of the us-east-1 ALB}"
: "${SECONDARY_ALB_ARN:?Set SECONDARY_ALB_ARN to the ARN of the eu-west-1 ALB}"

ACCELERATOR_ARN=$(aws globalaccelerator create-accelerator \
  --name global-app-accelerator \
  --ip-address-type IPV4 \
  --enabled \
  --region us-west-2 \
  --query 'Accelerator.AcceleratorArn' --output text)
echo "Accelerator ARN: $ACCELERATOR_ARN"

LISTENER_ARN=$(aws globalaccelerator create-listener \
  --accelerator-arn $ACCELERATOR_ARN \
  --protocol TCP \
  --port-ranges FromPort=80,ToPort=80 FromPort=443,ToPort=443 \
  --region us-west-2 \
  --query 'Listener.ListenerArn' --output text)
echo "Listener ARN: $LISTENER_ARN"

# Add endpoint group for the primary region (weight 128 = default 50%)
aws globalaccelerator create-endpoint-group \
  --listener-arn $LISTENER_ARN \
  --endpoint-group-region $PRIMARY_REGION \
  --traffic-dial-percentage 100 \
  --endpoint-configurations \
    "EndpointId=$PRIMARY_ALB_ARN,Weight=128,ClientIPPreservationEnabled=true" \
  --health-check-path "/health" \
  --health-check-interval-seconds 10 \
  --threshold-count 3 \
  --region us-west-2

# Add endpoint group for the secondary region (failover target)
aws globalaccelerator create-endpoint-group \
  --listener-arn $LISTENER_ARN \
  --endpoint-group-region $SECONDARY_REGION \
  --traffic-dial-percentage 100 \
  --endpoint-configurations \
    "EndpointId=$SECONDARY_ALB_ARN,Weight=128,ClientIPPreservationEnabled=true" \
  --health-check-path "/health" \
  --health-check-interval-seconds 10 \
  --threshold-count 3 \
  --region us-west-2

echo "Global Accelerator setup complete."
echo "Static IPs will be assigned within a few minutes — check the console."
