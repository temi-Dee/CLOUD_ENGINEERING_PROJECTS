# Project 4: RDS Database with Automated Backups

## Overview

Your application requires a managed relational database that is highly available and automatically backed up. Instead of managing database servers yourself, you will use Amazon RDS to deploy a PostgreSQL database with Multi-AZ redundancy, automated backups, and a secure network configuration. A bastion host provides safe administrative access to the database from your workstation.

## Prerequisites

Before starting this project, ensure you have:

1. An AWS account with RDS, EC2, and VPC permissions
2. AWS CLI installed and configured
3. A Bash shell (Linux/macOS) or WSL (Windows)
4. Basic understanding of relational databases and network security
5. PostgreSQL client tools installed locally (optional, for testing)

## Project Structure

```
AWS Project 4 - RDS Database/
├── deploy-rds.sh    # Automated deployment script
├── cleanup-rds.sh   # Automated cleanup script
└── README.md
```

## Steps

### 1. Create VPC and Networking

A dedicated VPC with private subnets keeps the database off the public internet.

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=RDS-VPC}]' \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Private subnets for RDS (two AZs required for Multi-AZ)
SUBNET1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

SUBNET2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)

# Public subnet for bastion host
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.10.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

# Internet gateway and route table for the public subnet
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

RTB_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RTB_ID \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUBLIC_SUBNET_ID
```

### 2. Create Security Groups

```bash
# RDS security group — accepts PostgreSQL traffic from the bastion only
RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name rds-security-group \
  --description "Security group for RDS PostgreSQL" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

# Bastion security group — accepts SSH from your IP only
BASTION_SG_ID=$(aws ec2 create-security-group \
  --group-name bastion-security-group \
  --description "Security group for bastion host" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $BASTION_SG_ID --protocol tcp --port 22 --cidr $MY_IP/32

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID --protocol tcp --port 5432 \
  --source-group $BASTION_SG_ID
```

### 3. Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name rds-subnet-group \
  --db-subnet-group-description "Subnet group for RDS" \
  --subnet-ids $SUBNET1_ID $SUBNET2_ID
```

### 4. Create RDS PostgreSQL Instance

```bash
# Custom parameter group for performance tuning
aws rds create-db-parameter-group \
  --db-parameter-group-name custom-postgres-params \
  --db-parameter-group-family postgres15 \
  --description "Custom PostgreSQL parameters"

aws rds modify-db-parameter-group \
  --db-parameter-group-name custom-postgres-params \
  --parameters \
    "ParameterName=max_connections,ParameterValue=200,ApplyMethod=pending-reboot" \
    "ParameterName=shared_buffers,ParameterValue=262144,ApplyMethod=pending-reboot"

# Launch RDS instance (takes 10-15 minutes)
aws rds create-db-instance \
  --db-instance-identifier my-postgres-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15.4 \
  --master-username dbadmin \
  --master-user-password "YourSecurePassword123!" \
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
  --no-publicly-accessible

# Wait for availability
aws rds wait db-instance-available --db-instance-identifier my-postgres-db

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier my-postgres-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "DB Endpoint: $DB_ENDPOINT"
```

### 5. Create Bastion Host

```bash
# Create key pair
aws ec2 create-key-pair --key-name bastion-key \
  --query 'KeyMaterial' --output text > bastion-key.pem
chmod 400 bastion-key.pem

# Get latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

# Launch bastion in the public subnet
BASTION_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t2.micro \
  --key-name bastion-key \
  --security-group-ids $BASTION_SG_ID \
  --subnet-id $PUBLIC_SUBNET_ID \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Bastion-Host}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $BASTION_ID

BASTION_IP=$(aws ec2 describe-instances \
  --instance-ids $BASTION_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "Bastion IP: $BASTION_IP"
echo "SSH: ssh -i bastion-key.pem ec2-user@$BASTION_IP"
```

### 6. Connect to the Database

From your workstation, SSH into the bastion, install the PostgreSQL client, and connect:

```bash
ssh -i bastion-key.pem ec2-user@$BASTION_IP

# On the bastion host:
sudo yum install postgresql15 -y
psql -h <DB_ENDPOINT> -U dbadmin -d postgres
```

### 7. Configure Monitoring and Alarms

Enable CloudWatch alarms to alert on key database metrics:

```bash
# CPU utilization alarm
aws cloudwatch put-metric-alarm \
  --alarm-name rds-high-cpu \
  --metric-name CPUUtilization \
  --namespace AWS/RDS \
  --dimensions Name=DBInstanceIdentifier,Value=my-postgres-db \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --statistic Average

# Free storage alarm
aws cloudwatch put-metric-alarm \
  --alarm-name rds-low-storage \
  --metric-name FreeStorageSpace \
  --namespace AWS/RDS \
  --dimensions Name=DBInstanceIdentifier,Value=my-postgres-db \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 2000000000 \
  --comparison-operator LessThanThreshold \
  --statistic Average
```

## Console Deployment

### 1. Create a VPC

1. Go to **VPC → Your VPCs → Create VPC**
   - **Name:** `RDS-VPC` | **IPv4 CIDR:** `10.0.0.0/16` → click **Create VPC**
2. Select the VPC → **Actions → Edit VPC settings** → enable **DNS hostnames** → save

### 2. Create Subnets

1. Go to **VPC → Subnets → Create subnet**, select `RDS-VPC`, then add three subnets:
   - **Name:** `rds-private-1a` | **AZ:** `us-east-1a` | **CIDR:** `10.0.1.0/24`
   - **Name:** `rds-private-1b` | **AZ:** `us-east-1b` | **CIDR:** `10.0.2.0/24`
   - **Name:** `bastion-public` | **AZ:** `us-east-1a` | **CIDR:** `10.0.10.0/24`
2. Select `bastion-public` → **Actions → Edit subnet settings** → enable **Auto-assign public IPv4** → save

### 3. Create Internet Gateway and Route Table

1. Go to **VPC → Internet Gateways → Create internet gateway** → **Name:** `RDS-VPC-IGW` → create → **Actions → Attach to VPC** → select `RDS-VPC`
2. Go to **VPC → Route Tables → Create route table** → **Name:** `public-rt` | **VPC:** `RDS-VPC` → create
3. Select `public-rt` → **Routes → Edit routes → Add route**: Destination `0.0.0.0/0`, Target: the internet gateway → **Save**
4. Select `public-rt` → **Subnet associations → Edit → associate `bastion-public`** → save

### 4. Create Security Groups

1. Go to **EC2 → Security Groups → Create security group**
   - **Name:** `bastion-sg` | **VPC:** `RDS-VPC`
   - **Inbound:** SSH | Port 22 | Source: **My IP** → click **Create**
2. Create a second security group:
   - **Name:** `rds-sg` | **VPC:** `RDS-VPC`
   - **Inbound:** PostgreSQL | Port 5432 | Source: select `bastion-sg` → click **Create**

### 5. Create DB Subnet Group

1. Go to **RDS → Subnet groups → Create DB subnet group**
   - **Name:** `rds-subnet-group` | **VPC:** `RDS-VPC`
   - Add subnets: `rds-private-1a` and `rds-private-1b` → click **Create**

### 6. Create RDS PostgreSQL Instance

1. Go to **RDS → Databases → Create database**
2. **Creation method:** Standard create | **Engine:** PostgreSQL | **Version:** 15.x
3. **Template:** Free tier (or Production for Multi-AZ)
4. **DB instance identifier:** `my-postgres-db`
5. **Master username:** `dbadmin` | set a strong **Master password**
6. **Instance type:** `db.t3.micro` | **Storage:** 20 GiB, gp3
7. **Connectivity:** VPC: `RDS-VPC` | Subnet group: `rds-subnet-group` | Public access: **No** | SG: `rds-sg`
8. **Additional configuration → Backup retention period:** 7 days | enable **Storage encryption**
9. Click **Create database** — takes 10–15 minutes

### 7. Create Bastion Host

1. Go to **EC2 → Key Pairs → Create key pair** → **Name:** `bastion-key` | RSA | .pem → download and save securely
2. Go to **EC2 → Launch instances**
   - **Name:** `Bastion-Host` | **AMI:** Amazon Linux 2023 | **Instance type:** `t2.micro`
   - **Key pair:** `bastion-key` | **Network:** `RDS-VPC` | **Subnet:** `bastion-public` | **Auto-assign public IP:** Enable
   - **Security group:** `bastion-sg` → click **Launch instance**
3. Copy the **Public IPv4 address** once the instance reaches the running state

### 8. Connect to the Database

SSH to the bastion, then connect to RDS (copy the endpoint from **RDS → Databases → my-postgres-db → Connectivity & security**):

```bash
ssh -i bastion-key.pem ec2-user@<BASTION_IP>
sudo yum install postgresql15 -y
psql -h <RDS_ENDPOINT> -U dbadmin -d postgres
```

### 9. Create CloudWatch Alarms

1. Go to **CloudWatch → Alarms → Create alarm → Select metric → RDS → Per-Database Metrics**
2. Select `my-postgres-db` → **CPUUtilization** → **Select metric**
   - **Period:** 5 min | **Threshold:** Greater than 80 | **Alarm name:** `rds-high-cpu` → create
3. Repeat for **FreeStorageSpace**, threshold Less than 2000000000 (2 GB), name `rds-low-storage`

### Console Cleanup

1. **RDS → Databases** → delete `my-postgres-db` (uncheck final snapshot for test environments)
2. **EC2 → Instances** → terminate `Bastion-Host`
3. **EC2 → Security Groups** → delete `rds-sg` then `bastion-sg`
4. **RDS → Subnet groups** → delete `rds-subnet-group`
5. **VPC** → delete subnets → delete route table → detach and delete IGW → delete `RDS-VPC`
6. **EC2 → Key Pairs** → delete `bastion-key`

---

## CLI / Automation

Use the provided scripts to create and tear down all resources automatically:

```bash
# Set DB_PASSWORD at the top of the script before running
chmod +x deploy-rds.sh
./deploy-rds.sh
```

Full deployment details (endpoint, IDs, connection commands) are saved to `deployment-info.txt`.

## Cleanup

```bash
chmod +x cleanup-rds.sh
./cleanup-rds.sh
```

The cleanup script:
1. Deletes the RDS instance (skipping the final snapshot) and waits for full deletion
2. Terminates the bastion host
3. Deletes the DB subnet group and parameter group
4. Deletes both security groups
5. Removes all VPC resources (subnets, route table, internet gateway, VPC)
6. Deletes the key pair and local `.pem` file

> Always run the cleanup script after finishing to avoid ongoing RDS and data transfer charges.

## Testing and Validation

1. SSH to the bastion: `ssh -i bastion-key.pem ec2-user@$BASTION_IP`
2. Install the PostgreSQL client on the bastion: `sudo yum install postgresql15 -y`
3. Connect to the database: `psql -h $DB_ENDPOINT -U dbadmin -d postgres`
4. Run basic SQL to confirm the connection:
   ```sql
   CREATE DATABASE testdb;
   \c testdb
   CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100), email VARCHAR(100));
   INSERT INTO users (name, email) VALUES ('Jane Doe', 'jane@example.com');
   SELECT * FROM users;
   ```
5. Verify automated backups exist under RDS > Automated backups in the AWS Console.
6. Confirm Multi-AZ status shows "Yes" in the RDS instance details.

## Learning Objectives

After completing this project, you will understand:

- Deploying managed relational databases with Amazon RDS
- Configuring Multi-AZ for automatic failover and high availability
- Setting up automated backups and point-in-time recovery
- Implementing secure database networking with private subnets
- Creating and using bastion hosts for database administration
- Monitoring database performance with CloudWatch metrics and alarms
- Applying encryption at rest and in transit
- Using parameter groups to tune database performance

## Troubleshooting

| Problem | Solution |
|---|---|
| Cannot connect to database | Check security group rules; confirm RDS is in the private subnet and only the bastion SG is allowed on port 5432 |
| Slow query performance | Review CloudWatch metrics and adjust parameter group settings (max_connections, shared_buffers) |
| Backup not appearing | Check that `backup-retention-period` is greater than 0 and the backup window is not conflicting with the maintenance window |
| Multi-AZ failover needed | Test with `aws rds reboot-db-instance --db-instance-identifier my-postgres-db --force-failover` |
