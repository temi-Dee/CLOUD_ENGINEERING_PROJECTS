# Project 6: Infrastructure as Code with Terraform

## Overview

Manually creating cloud resources through the AWS Console is error-prone and difficult to reproduce. You need a way to define your entire infrastructure as code, version control it, and deploy it consistently across environments. In this project you will use Terraform to provision a complete VPC, EC2, and RDS stack with modular reusable code and remote state management.

## Prerequisites

1. An AWS account with broad IAM permissions
2. Terraform installed (version 1.5 or later)
3. AWS CLI configured with credentials
4. Git installed for version control
5. Basic understanding of HCL (HashiCorp Configuration Language)
6. A text editor or IDE with Terraform support

## Project Structure

```
terraform-project/
├── backend.tf          # Remote state backend config
├── main.tf             # Root module (provider + module calls)
├── variables.tf        # Input variables
├── outputs.tf          # Output values
├── terraform.tfvars    # Variable values
└── modules/
    ├── vpc/            # VPC, subnets, route tables, security groups
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── ec2/            # EC2 instances
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── rds/            # RDS PostgreSQL instance
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## Steps

### Step 1: Set Up Remote State Backend

Create the S3 bucket and DynamoDB table that Terraform will use to store and lock state.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="terraform-state-${ACCOUNT_ID}"

# Create S3 bucket
aws s3 mb s3://$BUCKET_NAME

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket $BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

echo "Backend ready. Bucket: $BUCKET_NAME"
```

### Step 2: Configure the Backend

Edit `terraform-project/backend.tf` and replace `ACCOUNT_ID` with your actual account ID (or run `sed -i "s/ACCOUNT_ID/$ACCOUNT_ID/g" terraform-project/backend.tf`).

### Step 3: Initialize Terraform

```bash
cd terraform-project
terraform init
```

This downloads the AWS provider and configures the S3 remote backend.

### Step 4: Review and Set Variables

Copy or edit `terraform.tfvars`. The `db_username` and `db_password` variables have no defaults and must be supplied. You can set them in `terraform.tfvars` or pass them on the command line.

```bash
# Example: pass secrets via CLI (avoids storing in tfvars)
export TF_VAR_db_username="dbadmin"
export TF_VAR_db_password="YourSecurePassword123!"
```

### Step 5: Validate and Plan

```bash
# Check configuration syntax
terraform validate

# Preview all changes before applying
terraform plan -out=tfplan
```

Review the plan output carefully to confirm the resources that will be created.

### Step 6: Apply the Configuration

```bash
terraform apply tfplan
```

Terraform will provision the VPC, EC2 instances, and RDS database. This takes several minutes.

### Step 7: View Outputs

```bash
terraform output
```

Key outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `web_security_group_id`, `web_instance_id`, `db_instance_endpoint`.

### Step 8: Manage State

```bash
# List all resources in state
terraform state list

# Show details of a specific resource
terraform state show module.ec2.aws_instance.web

# Pull remote state to a local backup
terraform state pull > terraform.tfstate.backup
```

### Step 9: Make Changes and Update

Edit `terraform.tfvars` (for example, change `instance_type = "t3.small"`), then re-plan and apply:

```bash
terraform plan
terraform apply
```

Terraform shows exactly what will change, add, or be destroyed before making any modification.

## Console Deployment

> **Note:** Terraform is a CLI tool and cannot be replaced by the console. The console steps below set up the **remote state backend** resources manually, then you run Terraform from your terminal. The remaining subsections show what each Terraform module creates in the console so you can verify the deployment.

### 1. Create S3 Bucket for Terraform State

1. Go to **S3 → Create bucket**
   - **Bucket name:** `terraform-state-<your-account-id>` (must be globally unique)
   - **Region:** us-east-1
   - Keep **Block all public access** enabled
2. Click **Create bucket**
3. Open the bucket → **Properties → Bucket Versioning → Edit** → enable versioning → **Save**
4. Go to **Properties → Default encryption → Edit** → enable **SSE-S3** → **Save**

### 2. Create DynamoDB Table for State Locking

1. Go to **DynamoDB → Tables → Create table**
   - **Table name:** `terraform-state-lock`
   - **Partition key:** `LockID` (String)
   - **Billing mode:** On-demand
2. Click **Create table**

### 3. Initialize and Apply Terraform

Update `terraform-project/backend.tf` with your account ID, then from your terminal:

```bash
cd terraform-project
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 4. Verify Resources in the Console

After `terraform apply` completes, verify these resources were created:

| Resource | Console location |
|----------|-----------------|
| VPC | VPC → Your VPCs |
| Subnets, Route tables | VPC → Subnets / Route Tables |
| Security groups | EC2 → Security Groups |
| EC2 instances | EC2 → Instances |
| RDS instance | RDS → Databases |

### Console Cleanup

Run `terraform destroy` to remove all managed resources, then:

1. **DynamoDB** → delete `terraform-state-lock`
2. **S3** → empty and delete `terraform-state-<account-id>`

---

## CLI Automation

The `create-terraform-project.sh` script in the project root scaffolds the entire directory structure with all module files in one step:

```bash
bash create-terraform-project.sh
```

It creates a `terraform-infrastructure/` directory containing the same module layout, a ready-to-use `setup-backend.sh` script, and pre-populated configuration files.

## Cleanup

```bash
# Destroy all managed resources
terraform destroy

# Destroy a specific module only
terraform destroy -target=module.ec2

# After resources are gone, remove the state backend
aws s3 rm s3://$BUCKET_NAME --recursive
aws s3 rb s3://$BUCKET_NAME
aws dynamodb delete-table --table-name terraform-state-lock
```

## Testing and Validation

```bash
# Format all .tf files consistently
terraform fmt -recursive

# Validate configuration without accessing remote state
terraform validate

# Check that EC2 instances are running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=terraform-project-web" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}'

# Verify RDS is available
aws rds describe-db-instances \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address}'

# Import an existing resource into state
terraform import module.vpc.aws_vpc.main vpc-12345678
```

## Learning Objectives

After completing this project you will understand:

- Infrastructure as Code principles and benefits
- Terraform syntax and HCL configuration structure
- Creating reusable modules with input variables and outputs
- Managing remote state with S3 and state locking with DynamoDB
- Using `terraform plan` to preview changes safely
- Implementing multi-environment deployments with workspaces or separate state files
- Code review and testing for infrastructure changes
- Rebuilding environments from scratch for disaster recovery
