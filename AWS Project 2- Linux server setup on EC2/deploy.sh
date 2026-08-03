#!/bin/bash
# Project 2: Linux Server Setup on EC2
# Automated deployment script

set -e

echo "🚀 Starting EC2 Linux Server Setup..."

# Variables
KEY_NAME="web-server-key"
INSTANCE_TYPE="t2.micro"
REGION="us-east-1"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Step 1: Create IAM Role
echo -e "${BLUE}Step 1: Creating IAM Role...${NC}"
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
  --assume-role-policy-document file://ec2-trust-policy.json \
  2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
  --role-name WebServerRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  2>/dev/null || true

aws iam create-instance-profile --instance-profile-name WebServerProfile 2>/dev/null || true
aws iam add-role-to-instance-profile \
  --instance-profile-name WebServerProfile \
  --role-name WebServerRole 2>/dev/null || true

echo -e "${GREEN}✓ IAM Role created${NC}"

# Step 2: Create Key Pair
echo -e "${BLUE}Step 2: Creating Key Pair...${NC}"
if [ ! -f "$KEY_NAME.pem" ]; then
    aws ec2 create-key-pair \
      --key-name $KEY_NAME \
      --query 'KeyMaterial' \
      --output text > $KEY_NAME.pem
    chmod 400 $KEY_NAME.pem
    echo -e "${GREEN}✓ Key pair created: $KEY_NAME.pem${NC}"
else
    echo "Key pair already exists"
fi

# Step 3: Create Security Group
echo -e "${BLUE}Step 3: Creating Security Group...${NC}"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name web-server-sg \
  --description "Security group for web server" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text 2>/dev/null || aws ec2 describe-security-groups --group-names web-server-sg --query 'SecurityGroups[0].GroupId' --output text)

# Get your public IP
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr $MY_IP/32 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0 2>/dev/null || true

echo -e "${GREEN}✓ Security Group created: $SG_ID${NC}"

# Step 4: Get Latest Amazon Linux 2023 AMI
echo -e "${BLUE}Step 4: Getting latest AMI...${NC}"
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

echo -e "${GREEN}✓ Using AMI: $AMI_ID${NC}"

# Step 5: Create User Data Script
cat > user-data.sh << 'USERDATA'
#!/bin/bash
yum update -y
yum install -y nginx

# Configure Nginx
cat > /etc/nginx/conf.d/app.conf << 'NGINX'
server {
    listen 80;
    server_name _;
    
    location / {
        root /var/www/html;
        index index.html;
    }
    
    location /health {
        return 200 'healthy';
        add_header Content-Type text/plain;
    }
}
NGINX

# Create web page
mkdir -p /var/www/html
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

cat > /var/www/html/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <title>Project 2 - EC2 Web Server</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            background: rgba(255,255,255,0.1);
            padding: 30px;
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        h1 { margin-top: 0; }
        .info { background: rgba(0,0,0,0.2); padding: 15px; border-radius: 5px; margin: 10px 0; }
        .label { font-weight: bold; color: #ffd700; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Project 2: Linux Server on EC2</h1>
        <div class="info">
            <p><span class="label">Instance ID:</span> $INSTANCE_ID</p>
            <p><span class="label">Availability Zone:</span> $AZ</p>
            <p><span class="label">Server:</span> Nginx on Amazon Linux 2023</p>
            <p><span class="label">Status:</span> ✅ Running</p>
        </div>
        <p>This server was automatically configured with:</p>
        <ul>
            <li>SSH hardening</li>
            <li>Nginx web server</li>
            <li>CloudWatch monitoring</li>
            <li>IAM role for secure access</li>
        </ul>
    </div>
</body>
</html>
HTML

# Start and enable Nginx
systemctl start nginx
systemctl enable nginx

# SSH Hardening
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

echo "Setup complete!"
USERDATA

# Step 6: Launch EC2 Instance
echo -e "${BLUE}Step 6: Launching EC2 Instance...${NC}"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --iam-instance-profile Name=WebServerProfile \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Project2-WebServer},{Key=Project,Value=EC2-Setup}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo -e "${GREEN}✓ Instance launched: $INSTANCE_ID${NC}"

# Wait for instance to be running
echo -e "${BLUE}Waiting for instance to be running...${NC}"
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Instance ID: ${BLUE}$INSTANCE_ID${NC}"
echo -e "Public IP: ${BLUE}$PUBLIC_IP${NC}"
echo -e "SSH Command: ${BLUE}ssh -i $KEY_NAME.pem ec2-user@$PUBLIC_IP${NC}"
echo -e "Web URL: ${BLUE}http://$PUBLIC_IP${NC}"
echo ""
echo "⏳ Wait 2-3 minutes for user data script to complete, then visit the URL above"
echo ""

# Save instance info
cat > instance-info.txt << EOF
Instance ID: $INSTANCE_ID
Public IP: $PUBLIC_IP
Security Group: $SG_ID
Key Pair: $KEY_NAME.pem
SSH Command: ssh -i $KEY_NAME.pem ec2-user@$PUBLIC_IP
Web URL: http://$PUBLIC_IP
EOF

echo "Instance info saved to instance-info.txt"
: