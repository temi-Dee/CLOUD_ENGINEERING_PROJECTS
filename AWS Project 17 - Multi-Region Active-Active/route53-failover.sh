#!/bin/bash
# Route 53 health-check based DNS failover for multi-region active-active setup.
# Pairs with global-accelerator/setup.sh — run this after ALBs exist in both regions.
#
# Required env vars:
#   PRIMARY_ALB_DNS             e.g. my-alb-1234.us-east-1.elb.amazonaws.com
#   PRIMARY_ALB_HOSTED_ZONE_ID  Hosted zone ID of the us-east-1 ALB (from aws elbv2 describe-load-balancers)
#   SECONDARY_ALB_DNS           e.g. my-alb-5678.eu-west-1.elb.amazonaws.com
#   SECONDARY_ALB_HOSTED_ZONE_ID
#   ROUTE53_HOSTED_ZONE_ID      Your domain's hosted zone ID
#   DOMAIN_NAME                 e.g. app.example.com

set -e

: "${PRIMARY_ALB_DNS:?Set PRIMARY_ALB_DNS}"
: "${PRIMARY_ALB_HOSTED_ZONE_ID:?Set PRIMARY_ALB_HOSTED_ZONE_ID}"
: "${SECONDARY_ALB_DNS:?Set SECONDARY_ALB_DNS}"
: "${SECONDARY_ALB_HOSTED_ZONE_ID:?Set SECONDARY_ALB_HOSTED_ZONE_ID}"
: "${ROUTE53_HOSTED_ZONE_ID:?Set ROUTE53_HOSTED_ZONE_ID}"
: "${DOMAIN_NAME:?Set DOMAIN_NAME}"

PRIMARY_REGION="us-east-1"
SECONDARY_REGION="eu-west-1"

echo "Creating Route 53 health check for primary ALB ($PRIMARY_REGION)..."
PRIMARY_HC_ID=$(aws route53 create-health-check \
  --caller-reference "primary-$(date +%s)" \
  --health-check-config \
    "Type=HTTP,FullyQualifiedDomainName=$PRIMARY_ALB_DNS,Port=80,ResourcePath=/health,RequestInterval=10,FailureThreshold=3" \
  --query 'HealthCheck.Id' --output text)
echo "  Primary health check ID: $PRIMARY_HC_ID"

echo "Creating Route 53 health check for secondary ALB ($SECONDARY_REGION)..."
SECONDARY_HC_ID=$(aws route53 create-health-check \
  --caller-reference "secondary-$(date +%s)" \
  --health-check-config \
    "Type=HTTP,FullyQualifiedDomainName=$SECONDARY_ALB_DNS,Port=80,ResourcePath=/health,RequestInterval=10,FailureThreshold=3" \
  --query 'HealthCheck.Id' --output text)
echo "  Secondary health check ID: $SECONDARY_HC_ID"

echo "Creating PRIMARY and SECONDARY failover alias records for $DOMAIN_NAME..."
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
  --change-batch "{
    \"Comment\": \"Multi-region failover routing for $DOMAIN_NAME\",
    \"Changes\": [
      {
        \"Action\": \"CREATE\",
        \"ResourceRecordSet\": {
          \"Name\": \"$DOMAIN_NAME\",
          \"Type\": \"A\",
          \"SetIdentifier\": \"primary-$PRIMARY_REGION\",
          \"Failover\": \"PRIMARY\",
          \"HealthCheckId\": \"$PRIMARY_HC_ID\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"$PRIMARY_ALB_HOSTED_ZONE_ID\",
            \"DNSName\": \"$PRIMARY_ALB_DNS\",
            \"EvaluateTargetHealth\": true
          }
        }
      },
      {
        \"Action\": \"CREATE\",
        \"ResourceRecordSet\": {
          \"Name\": \"$DOMAIN_NAME\",
          \"Type\": \"A\",
          \"SetIdentifier\": \"secondary-$SECONDARY_REGION\",
          \"Failover\": \"SECONDARY\",
          \"HealthCheckId\": \"$SECONDARY_HC_ID\",
          \"AliasTarget\": {
            \"HostedZoneId\": \"$SECONDARY_ALB_HOSTED_ZONE_ID\",
            \"DNSName\": \"$SECONDARY_ALB_DNS\",
            \"EvaluateTargetHealth\": true
          }
        }
      }
    ]
  }"

echo ""
echo "Route 53 failover routing configured for $DOMAIN_NAME"
echo "  PRIMARY   -> $PRIMARY_REGION  ($PRIMARY_ALB_DNS)"
echo "  SECONDARY -> $SECONDARY_REGION ($SECONDARY_ALB_DNS)"
echo ""
echo "DNS will automatically failover to $SECONDARY_REGION when the primary health check fails 3 consecutive checks."
