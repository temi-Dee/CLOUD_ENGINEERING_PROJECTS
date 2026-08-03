#!/bin/bash
# Project 4: RDS Database Cleanup Script

set -e

echo "🧹 Cleaning up RDS Database resources..."

REGION="us-east-1"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Read deployment info
if [ -f deployment-info.txt ]; then
    VPC_ID=$(grep "VPC ID:" deployment-info.txt | awk '{print $3}')
    BASTION_ID=$(grep "Instance ID:" deployment-info.txt | tail -1 | awk '{print $3}')
    RDS_SG_ID=$(grep "RDS Security Group:" deployment-info.txt | awk '{print $4}')
    BASTION_SG_ID=$(grep "Bastion Security Group:" deployment-info.txt | awk '{print $4}')
    SUBNET1_ID=$(grep "Private Subnet 1:" deployment-info.txt | awk '{print $4}')
    SUBNET2_ID=$(grep "Private Subnet 2:" deployment-info.txt | awk '{print $4}')
    PUBLIC_SUBNET_ID=$(grep "Public Subnet:" deployment-info.txt | awk '{print $3}')
fi

# Step 1: Delete RDS instance
echo -e "${BLUE}Step 1: Deleting RDS instance...${NC}"
aws rds delete-db-instance \
  --db-instance-identifier my-postgres-db \
  --skip-final-snapshot \
  --region $REGION 2>/dev/null || echo "RDS instance not found"

echo -e "${YELLOW}⏳ Waiting for RDS deletion (this takes 5-10 minutes)...${NC}"
aws rds wait db-instance-deleted --db-instance-identifier my-postgres-db --region $REGION 2>/dev/null || true

echo -e "${GREEN}✓ RDS instance deleted${NC}"

# Step 2: Terminate bastion host
echo -e "${BLUE}Step 2: Terminating bastion host...${NC}"
if [ ! -z "$BASTION_ID" ]; then
    aws ec2 terminate-instances --instance-ids $BASTION_ID --region $REGION 2>/dev/null || true
    aws ec2 wait instance-terminated --instance-ids $BASTION_ID --region $REGION 2>/dev/null || true
fi
echo -e "${GREEN}✓ Bastion host terminated${NC}"

# Step 3: Delete DB subnet group
echo -e "${BLUE}Step 3: Deleting DB subnet group...${NC}"
aws rds delete-db-subnet-group --db-subnet-group-name rds-subnet-group --region $REGION 2>/dev/null || true
echo -e "${GREEN}✓ DB subnet group deleted${NC}"

# Step 4: Delete parameter group
echo -e "${BLUE}Step 4: Deleting parameter group...${NC}"
aws rds delete-db-parameter-group --db-parameter-group-name custom-postgres-params --region $REGION 2>/dev/null || true
echo -e "${GREEN}✓ Parameter group deleted${NC}"

# Step 5: Delete security groups
echo -e "${BLUE}Step 5: Deleting security groups...${NC}"
sleep 30  # Wait for network interfaces to detach
if [ ! -z "$RDS_SG_ID" ]; then
    aws ec2 delete-security-group --group-id $RDS_SG_ID --region $REGION 2>/dev/null || true
fi
if [ ! -z "$BASTION_SG_ID" ]; then
    aws ec2 delete-security-group --group-id $BASTION_SG_ID --region $REGION 2>/dev/null || true
fi
echo -e "${GREEN}✓ Security groups deleted${NC}"

# Step 6: Delete VPC resources
echo -e "${BLUE}Step 6: Deleting VPC resources...${NC}"
if [ ! -z "$VPC_ID" ]; then
    # Get IGW and RTB
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text --region $REGION)
    RTB_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=Public-RTB" --query 'RouteTables[0].RouteTableId' --output text --region $REGION)
    
    # Detach and delete IGW
    if [ "$IGW_ID" != "None" ]; then
        aws ec2 detach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION 2>/dev/null || true
    fi
    
    # Delete subnets
    [ ! -z "$SUBNET1_ID" ] && aws ec2 delete-subnet --subnet-id $SUBNET1_ID --region $REGION 2>/dev/null || true
    [ ! -z "$SUBNET2_ID" ] && aws ec2 delete-subnet --subnet-id $SUBNET2_ID --region $REGION 2>/dev/null || true
    [ ! -z "$PUBLIC_SUBNET_ID" ] && aws ec2 delete-subnet --subnet-id $PUBLIC_SUBNET_ID --region $REGION 2>/dev/null || true
    
    # Delete route table
    if [ "$RTB_ID" != "None" ]; then
        aws ec2 delete-route-table --route-table-id $RTB_ID --region $REGION 2>/dev/null || true
    fi
    
    # Delete VPC
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION 2>/dev/null || true
fi
echo -e "${GREEN}✓ VPC resources deleted${NC}"

# Step 7: Delete key pair
echo -e "${BLUE}Step 7: Deleting key pair...${NC}"
aws ec2 delete-key-pair --key-name bastion-key --region $REGION 2>/dev/null || true
rm -f bastion-key.pem
echo -e "${GREEN}✓ Key pair deleted${NC}"

# Clean up local files
rm -f deployment-info.txt

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Cleanup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "All RDS resources have been deleted."
echo ""
