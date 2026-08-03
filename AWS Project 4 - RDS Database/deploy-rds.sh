#!/bin/bash
# Project 4: RDS Database with Automated Backups
# Automated deployment script

set -e

echo "🚀 Deploying RDS PostgreSQL Database..."

# Variables
REGION="us-east-1"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Require DB_PASSWORD to be supplied via environment variable — never hard-code it
if [ -z "${DB_PASSWORD:-}" ]; then
    echo -e "${YELLOW}ERROR: DB_PASSWORD environment variable must be set before running this script.${NC}"
    echo "  Example: export DB_PASSWORD=\$(aws secretsmanager get-secret-value --secret-id prod/db/master --query SecretString --output text | jq -r .password)"
    exit 1
fi

# Step 1: Create VPC and Subnets
echo -e "${BLUE}Step 1: Creating VPC and Subnets...${NC}"
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=RDS-VPC}]' \
  --query 'Vpc.VpcId' \
  --output text \
  --region $REGION)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION

SUBNET1_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone ${REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=RDS-Private-Subnet-1}]' \
  --query 'Subnet.SubnetId' \
  --output text \
  --region $REGION)

SUBNET2_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone ${REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=RDS-Private-Subnet-2}]' \
  --query 'Subnet.SubnetId' \
  --output text \
  --region $REGION)

PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.10.0/24 \
  --availability-zone ${REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=Public-Subnet}]' \
  --query 'Subnet.SubnetId' \
  --output text \
  --region $REGION)

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=RDS-IGW}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region $REGION)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

RTB_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=Public-RTB}]' \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region $REGION)

aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUBLIC_SUBNET_ID --region $REGION

echo -e "${GREEN}✓ VPC and Subnets created${NC}"

# Step 2: Create DB Subnet Group
echo -e "${BLUE}Step 2: Creating DB Subnet Group...${NC}"
aws rds create-db-subnet-group \
  --db-subnet-group-name rds-subnet-group \
  --db-subnet-group-description "Subnet group for RDS" \
  --subnet-ids $SUBNET1_ID $SUBNET2_ID \
  --tags Key=Name,Value=RDS-Subnet-Group \
  --region $REGION

echo -e "${GREEN}✓ DB Subnet Group created${NC}"

# Step 3: Create Security Groups
echo -e "${BLUE}Step 3: Creating Security Groups...${NC}"
RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name rds-security-group \
  --description "Security group for RDS PostgreSQL" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text \
  --region $REGION)

BASTION_SG_ID=$(aws ec2 create-security-group \
  --group-name bastion-security-group \
  --description "Security group for bastion host" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text \
  --region $REGION)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $BASTION_SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr $MY_IP/32 \
  --region $REGION

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $BASTION_SG_ID \
  --region $REGION

echo -e "${GREEN}✓ Security Groups created${NC}"

# Step 4: Create Parameter Group
echo -e "${BLUE}Step 4: Creating Parameter Group...${NC}"
aws rds create-db-parameter-group \
  --db-parameter-group-name custom-postgres-params \
  --db-parameter-group-family postgres15 \
  --description "Custom PostgreSQL parameters" \
  --region $REGION

aws rds modify-db-parameter-group \
  --db-parameter-group-name custom-postgres-params \
  --parameters "ParameterName=max_connections,ParameterValue=200,ApplyMethod=pending-reboot" \
               "ParameterName=shared_buffers,ParameterValue=262144,ApplyMethod=pending-reboot" \
  --region $REGION

echo -e "${GREEN}✓ Parameter Group created${NC}"

# Step 5: Create RDS Instance
echo -e "${BLUE}Step 5: Creating RDS Instance (this takes 10-15 minutes)...${NC}"
aws rds create-db-instance \
  --db-instance-identifier my-postgres-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15 \
  --master-username dbadmin \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --db-subnet-group-name rds-subnet-group \
  --vpc-security-group-ids $RDS_SG_ID \
  --db-parameter-group-name custom-postgres-params \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --multi-az \
  --auto-minor-version-upgrade \
  --publicly-accessible false \
  --tags Key=Name,Value=Production-PostgreSQL Key=Environment,Value=Production \
  --region $REGION

echo -e "${YELLOW}⏳ Waiting for RDS instance to be available...${NC}"
aws rds wait db-instance-available --db-instance-identifier my-postgres-db --region $REGION

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier my-postgres-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region $REGION)

echo -e "${GREEN}✓ RDS Instance created${NC}"

# Step 6: Launch Bastion Host
echo -e "${BLUE}Step 6: Launching Bastion Host...${NC}"
aws ec2 create-key-pair --key-name bastion-key --query 'KeyMaterial' --output text --region $REGION > bastion-key.pem
chmod 400 bastion-key.pem

AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region $REGION)

BASTION_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t2.micro \
  --key-name bastion-key \
  --security-group-ids $BASTION_SG_ID \
  --subnet-id $PUBLIC_SUBNET_ID \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Bastion-Host}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region $REGION)

aws ec2 wait instance-running --instance-ids $BASTION_ID --region $REGION

BASTION_IP=$(aws ec2 describe-instances \
  --instance-ids $BASTION_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region $REGION)

echo -e "${GREEN}✓ Bastion Host launched${NC}"

# Save deployment info
cat > deployment-info.txt << EOF
RDS Database Deployment Information
====================================

Database Details:
- Instance ID: my-postgres-db
- Endpoint: $DB_ENDPOINT
- Port: 5432
- Username: dbadmin
- Password: (stored in \$DB_PASSWORD env var — do not log here)
- Engine: PostgreSQL 15
- Multi-AZ: Enabled
- Backup Retention: 7 days

Network Details:
- VPC ID: $VPC_ID
- Private Subnet 1: $SUBNET1_ID
- Private Subnet 2: $SUBNET2_ID
- Public Subnet: $PUBLIC_SUBNET_ID
- RDS Security Group: $RDS_SG_ID
- Bastion Security Group: $BASTION_SG_ID

Bastion Host:
- Instance ID: $BASTION_ID
- Public IP: $BASTION_IP
- Key File: bastion-key.pem

Connection Instructions:
1. SSH to bastion:
   ssh -i bastion-key.pem ec2-user@$BASTION_IP

2. Install PostgreSQL client on bastion:
   sudo yum install postgresql15 -y

3. Connect to database:
   psql -h $DB_ENDPOINT -U dbadmin -d postgres

4. Enter the password from your secrets store when prompted.

Test Commands:
CREATE DATABASE testdb;
\c testdb
CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100), email VARCHAR(100));
INSERT INTO users (name, email) VALUES ('John Doe', 'john@example.com');
SELECT * FROM users;

Cleanup:
Run ./cleanup-rds.sh to delete all resources
EOF

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Database Endpoint: ${BLUE}$DB_ENDPOINT${NC}"
echo -e "Bastion Host IP: ${BLUE}$BASTION_IP${NC}"
echo -e "SSH Command: ${BLUE}ssh -i bastion-key.pem ec2-user@$BASTION_IP${NC}"
echo ""
echo "📝 Full deployment details saved to deployment-info.txt"
echo ""
