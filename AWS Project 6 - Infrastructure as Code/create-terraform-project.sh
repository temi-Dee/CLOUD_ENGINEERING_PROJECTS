#!/bin/bash
# Project 6: Create Complete Terraform Project Structure

set -e

echo "🚀 Creating Terraform Infrastructure as Code Project..."

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="terraform-infrastructure"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create project structure
echo -e "${BLUE}Creating project structure...${NC}"
mkdir -p $PROJECT_DIR/modules/{vpc,ec2,rds}

cd $PROJECT_DIR

# Create backend.tf
cat > backend.tf << 'EOF'
terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    bucket         = "terraform-state-ACCOUNT_ID"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "Terraform-IaC"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}
EOF

# Replace ACCOUNT_ID
sed -i "s/ACCOUNT_ID/$ACCOUNT_ID/g" backend.tf

# Create variables.tf
cat > variables.tf << 'EOF'
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "terraform-project"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  sensitive   = true
  default     = "dbadmin"
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}
EOF

# Create terraform.tfvars
cat > terraform.tfvars << 'EOF'
aws_region    = "us-east-1"
environment   = "dev"
project_name  = "terraform-project"
vpc_cidr      = "10.0.0.0/16"
instance_type = "t2.micro"
db_password   = "ChangeMe123!"
EOF

# Create main.tf
cat > main.tf << 'EOF'
module "vpc" {
  source = "./modules/vpc"
  
  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
}

module "ec2" {
  source = "./modules/ec2"
  
  project_name      = var.project_name
  instance_type     = var.instance_type
  instance_count    = 2
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.web_security_group_id
}

module "rds" {
  source = "./modules/rds"
  
  project_name      = var.project_name
  username          = var.db_username
  password          = var.db_password
  subnet_ids        = module.vpc.private_subnet_ids
  security_group_id = module.vpc.database_security_group_id
  multi_az          = false
}
EOF

# Create outputs.tf
cat > outputs.tf << 'EOF'
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "ec2_public_ips" {
  description = "EC2 public IPs"
  value       = module.ec2.public_ips
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.endpoint
  sensitive   = true
}
EOF

# Create VPC module
cat > modules/vpc/main.tf << 'EOF'
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
    Type = "Public"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
    Type = "Private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Security group for web servers"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-db-sg"
  description = "Security group for database"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-db-sg"
  }
}
EOF

cat > modules/vpc/variables.tf << 'EOF'
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
}
EOF

cat > modules/vpc/outputs.tf << 'EOF'
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "web_security_group_id" {
  description = "Web security group ID"
  value       = aws_security_group.web.id
}

output "database_security_group_id" {
  description = "Database security group ID"
  value       = aws_security_group.database.id
}
EOF

# Create EC2 module
cat > modules/ec2/main.tf << 'EOF'
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_instance" "web" {
  count                  = var.instance_count
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = [var.security_group_id]
  key_name               = aws_key_pair.main.key_name
  
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Terraform Instance ${count.index + 1}</h1>" > /var/www/html/index.html
              EOF
  
  tags = {
    Name = "${var.project_name}-web-${count.index + 1}"
  }
}
EOF

cat > modules/ec2/variables.tf << 'EOF'
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "instance_count" {
  description = "Number of instances"
  type        = number
  default     = 2
}

variable "subnet_ids" {
  description = "Subnet IDs"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID"
  type        = string
}
EOF

cat > modules/ec2/outputs.tf << 'EOF'
output "instance_ids" {
  description = "EC2 instance IDs"
  value       = aws_instance.web[*].id
}

output "public_ips" {
  description = "Public IP addresses"
  value       = aws_instance.web[*].public_ip
}
EOF

# Create RDS module
cat > modules/rds/main.tf << 'EOF'
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids
  
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-db"
  engine                 = "postgres"
  engine_version         = "15.4"
  instance_class         = var.instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  
  db_name  = var.database_name
  username = var.username
  password = var.password
  
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "mon:04:00-mon:05:00"
  
  multi_az               = var.multi_az
  publicly_accessible    = false
  skip_final_snapshot    = true
  
  tags = {
    Name = "${var.project_name}-db"
  }
}
EOF

cat > modules/rds/variables.tf << 'EOF'
variable "project_name" {
  description = "Project name"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "database_name" {
  description = "Database name"
  type        = string
  default     = "mydb"
}

variable "username" {
  description = "Master username"
  type        = string
  sensitive   = true
}

variable "password" {
  description = "Master password"
  type        = string
  sensitive   = true
}

variable "subnet_ids" {
  description = "Subnet IDs"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID"
  type        = string
}

variable "multi_az" {
  description = "Enable Multi-AZ"
  type        = bool
  default     = false
}
EOF

cat > modules/rds/outputs.tf << 'EOF'
output "endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.endpoint
}

output "database_name" {
  description = "Database name"
  value       = aws_db_instance.main.db_name
}
EOF

# Create setup script
cat > setup-backend.sh << EOF
#!/bin/bash
# Setup Terraform backend (S3 + DynamoDB)

set -e

echo "Setting up Terraform backend..."

BUCKET_NAME="terraform-state-$ACCOUNT_ID"

# Create S3 bucket
aws s3 mb s3://\$BUCKET_NAME

# Enable versioning
aws s3api put-bucket-versioning \\
  --bucket \$BUCKET_NAME \\
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \\
  --bucket \$BUCKET_NAME \\
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Create DynamoDB table
aws dynamodb create-table \\
  --table-name terraform-state-lock \\
  --attribute-definitions AttributeName=LockID,AttributeType=S \\
  --key-schema AttributeName=LockID,KeyType=HASH \\
  --billing-mode PAY_PER_REQUEST

echo "✓ Backend setup complete!"
echo "Bucket: \$BUCKET_NAME"
echo "DynamoDB Table: terraform-state-lock"
EOF

chmod +x setup-backend.sh

# Create README
cat > README.md << 'EOF'
# Terraform Infrastructure Project

Complete infrastructure as code using Terraform modules.

## Setup

1. Setup backend:
```bash
./setup-backend.sh
```

2. Initialize Terraform:
```bash
terraform init
```

3. Plan deployment:
```bash
terraform plan
```

4. Apply configuration:
```bash
terraform apply
```

5. Destroy resources:
```bash
terraform destroy
```

## Modules

- **VPC**: Network infrastructure
- **EC2**: Web servers
- **RDS**: PostgreSQL database

## Outputs

- VPC ID
- EC2 public IPs
- RDS endpoint
EOF

cd ..

echo -e "${GREEN}✓ Terraform project created: $PROJECT_DIR${NC}"
echo ""
echo "Next steps:"
echo "1. cd $PROJECT_DIR"
echo "2. ./setup-backend.sh"
echo "3. terraform init"
echo "4. terraform plan"
echo "5. terraform apply"
echo ""
