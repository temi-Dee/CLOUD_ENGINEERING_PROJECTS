# Project 18: Platform Engineering - Internal Developer Platform

## Overview

Modern DevOps requires more than infrastructure automation — it requires a platform that enables developers to self-serve their infrastructure needs. Internal Developer Platforms (IDPs) reduce friction by providing pre-built, tested infrastructure components as reusable modules. In this project you will build an IDP with a versioned Terraform module registry, a Backstage service catalog, and golden-path templates that guide teams toward best practices.

## Prerequisites

- AWS account with an EKS cluster running
- GitHub organization with admin access
- Node.js 18+ and Docker installed locally
- Terraform CLI installed (>= 1.0)
- Helm 3 installed
- Basic understanding of Kubernetes and Terraform

## Project Structure

```
AWS Project 18 - Platform Engineering/
├── README.md
├── backstage/
│   └── package.json                    # Backstage app dependencies
└── terraform-modules/
    └── vpc/
        ├── main.tf                     # VPC, subnets, internet gateway, route tables
        ├── variables.tf                # Input variables for the VPC module
        └── outputs.tf                  # Output values exported by the VPC module
```

## Steps

### Step 1: Create the Terraform Module Repository

```bash
git clone https://github.com/YOUR-ORG/terraform-modules.git
cd terraform-modules
mkdir -p modules/vpc
```

Copy the files from `terraform-modules/vpc/` into `modules/vpc/`. The module creates a VPC with public subnets, an internet gateway, and a public route table.

Example usage of the module from a consumer configuration:

```hcl
module "vpc" {
  source = "github.com/YOUR-ORG/terraform-modules//modules/vpc?ref=modules/vpc/v1.0.0"

  name           = "production-vpc"
  cidr_block     = "10.0.0.0/16"
  environment    = "production"
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}
```

### Step 2: Version and Tag the Module

```bash
git add modules/vpc/
git commit -m "Add VPC module v1.0.0"
git tag modules/vpc/v1.0.0
git push origin main --tags
```

Tags use the format `modules/<name>/v<semver>` so that consumers can pin to exact versions and the GitHub Actions publishing workflow can identify module names and versions from the tag.

### Step 3: Add the Module Publishing Workflow

```bash
mkdir -p .github/workflows

cat > .github/workflows/publish-module.yaml << 'EOF'
name: Publish Terraform Module

on:
  push:
    tags:
      - 'modules/**/*'

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - name: Validate and publish module
        run: |
          MODULE_NAME=$(echo "${{ github.ref_name }}" | cut -d/ -f2)
          VERSION=$(echo "${{ github.ref_name }}" | cut -d/ -f3)
          echo "Publishing module: $MODULE_NAME version: $VERSION"
          cd modules/$MODULE_NAME
          terraform init
          terraform validate
EOF
```

### Step 4: Install and Configure Backstage

```bash
npx @backstage/create-app@latest --path=backstage
cd backstage

# Install dependencies (uses package.json in backstage/)
yarn install
```

Configure `app-config.yaml` with AWS and GitHub integration:

```yaml
integrations:
  github:
    - host: github.com
      token: ${GITHUB_TOKEN}

techdocs:
  builder: local
  generator:
    runIn: docker
  publisher:
    type: awsS3
    awsS3:
      bucketName: backstage-techdocs
      region: us-east-1
```

Start the development server:

```bash
yarn dev
```

### Step 5: Create the ECS Service Golden-Path Template

```bash
mkdir -p backstage/catalog/templates

cat > backstage/catalog/templates/ecs-service.yaml << 'EOF'
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: ecs-service
  title: "ECS Service Golden Path"
  description: "Deploy a containerised service to ECS with production best practices"
spec:
  owner: platform-team
  type: service
  parameters:
    - title: Service Details
      required: [name, description, owner]
      properties:
        name:
          type: string
          title: Service Name
        description:
          type: string
          title: Description
        owner:
          type: string
          title: Team Owner
    - title: Infrastructure
      properties:
        cpu:
          type: string
          enum: ["256", "512", "1024", "2048"]
          default: "512"
        memory:
          type: string
          enum: ["512", "1024", "2048", "4096"]
          default: "1024"
  steps:
    - id: fetch-template
      name: Fetch Template
      action: fetch:template
      input:
        url: ./skeleton
    - id: publish-repo
      name: Publish Repository
      action: publish:github
      input:
        allowedHosts: ['github.com']
        repoUrl: github.com?repo=${{ parameters.name }}&owner=YOUR-ORG
    - id: register-catalog
      name: Register in Catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps['publish-repo'].output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml
EOF
```

### Step 6: Create the TechDocs Site

```bash
mkdir -p backstage/docs/platform

cat > backstage/docs/mkdocs.yml << 'EOF'
site_name: Internal Developer Platform
nav:
  - Home: index.md
  - Golden Paths:
      - ECS Service: golden-paths/ecs-service.md
      - RDS Database: golden-paths/rds-database.md
  - Module Registry:
      - VPC Module: modules/vpc.md
EOF

cat > backstage/docs/index.md << 'EOF'
# Internal Developer Platform

## Golden Paths

Use these templates to provision standardised, production-ready infrastructure:

- [Deploy ECS Service](golden-paths/ecs-service.md)
- [Create RDS Database](golden-paths/rds-database.md)

## Terraform Module Registry

Versioned, reusable modules sourced from the `terraform-modules` repository:

- [VPC Module](modules/vpc.md) - VPC with public subnets and internet gateway
EOF
```

### Step 7: Deploy Backstage to EKS

```bash
# Create S3 bucket for TechDocs
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 mb s3://backstage-techdocs-${ACCOUNT_ID} --region us-east-1

# Build and push Backstage Docker image to ECR
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
aws ecr create-repository --repository-name backstage --region us-east-1
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

cd backstage
yarn build
docker build -t backstage .
docker tag backstage:latest $ECR_REGISTRY/backstage:latest
docker push $ECR_REGISTRY/backstage:latest
cd ..

# Deploy via Helm
helm repo add backstage https://backstage.github.io/charts
helm repo update

cat > backstage-values.yaml << EOF
backstage:
  image:
    registry: ${ECR_REGISTRY}
    repository: backstage
    tag: latest
  appConfig:
    app:
      title: Internal Developer Platform
      baseUrl: https://backstage.example.com

postgresql:
  enabled: true

ingress:
  enabled: true
  host: backstage.example.com
EOF

helm install backstage backstage/backstage \
  --namespace backstage \
  --create-namespace \
  -f backstage-values.yaml
```

### Step 8: Configure GitHub OIDC and Kubernetes RBAC

```bash
# Register GitHub Actions as an OIDC identity provider
aws iam create-openid-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Create a Kubernetes service account for platform users
kubectl create serviceaccount platform-user --namespace default
kubectl create clusterrolebinding platform-user-edit \
  --clusterrole=edit \
  --serviceaccount=default:platform-user
```

## Console Deployment

> **Note:** Platform Engineering is primarily code-driven (Terraform, Backstage, Helm). The console steps below cover the AWS resource prerequisites. The rest requires local tools.

### 1. Create GitHub Repository for Terraform Modules (GitHub UI)

1. Go to **github.com → New repository**
   - **Name:** `terraform-modules` | **Visibility:** Private → **Create**
2. Copy the `terraform-modules/vpc/` files from this project into the repo under `modules/vpc/`
3. Push and create the tag: `modules/vpc/v1.0.0` (via GitHub UI: **Releases → Create a new release**)

### 2. Create S3 Bucket for TechDocs

1. Go to **S3 → Create bucket**
   - **Name:** `backstage-techdocs-<account-id>` | **Region:** us-east-1
   - Keep **Block all public access** enabled
2. Click **Create bucket**
3. Add a bucket policy allowing the EKS service account to read/write objects (use the ARN from your IRSA service account)

### 3. Create ECR Repository for Backstage

1. Go to **ECR → Repositories → Create repository**
   - **Visibility:** Private | **Name:** `backstage` → **Create**
2. Click **View push commands** to get the Docker login, tag, and push commands for your terminal

### 4. Create IAM OIDC Provider for GitHub Actions

1. Go to **IAM → Identity providers → Add provider**
   - **Provider type:** OpenID Connect
   - **URL:** `https://token.actions.githubusercontent.com` → **Get thumbprint**
   - **Audience:** `sts.amazonaws.com` → **Add provider**

### 5. Build and Deploy Backstage (requires local tools)

After completing the AWS console setup, run from your terminal:

```bash
# Install and build Backstage
npx @backstage/create-app@latest --path=backstage
cd backstage
yarn install && yarn build

# Build and push Docker image
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -t backstage .
docker tag backstage:latest $ECR_REGISTRY/backstage:latest
docker push $ECR_REGISTRY/backstage:latest

# Deploy to EKS
helm repo add backstage https://backstage.github.io/charts
helm install backstage backstage/backstage --namespace backstage --create-namespace -f backstage-values.yaml
```

### 6. Access Backstage via Browser

```bash
kubectl port-forward svc/backstage 7007:7007 -n backstage
```

Open `http://localhost:7007` in your browser to use the Internal Developer Platform.

### Console Cleanup

1. **ECR** → delete `backstage` repository
2. **S3** → empty and delete `backstage-techdocs-<account-id>`
3. **IAM → Identity providers** → delete `token.actions.githubusercontent.com`
4. Run `helm uninstall backstage -n backstage && kubectl delete namespace backstage`

---

## CLI Automation Summary

Key variables used across steps:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
```

## Testing and Validation

```bash
# Validate the Terraform VPC module
cd terraform-modules/vpc
terraform init
terraform validate
terraform plan -var="name=test-vpc" -var="environment=staging"

# Verify Backstage pods are running
kubectl get pods -n backstage

# Check Backstage is accessible
kubectl port-forward svc/backstage 7007:7007 -n backstage
curl http://localhost:7007/api/catalog/entities
```

## Cleanup

```bash
# Remove Backstage from EKS
helm uninstall backstage -n backstage
kubectl delete namespace backstage

# Delete ECR image and repository
aws ecr batch-delete-image \
  --repository-name backstage \
  --image-ids imageTag=latest
aws ecr delete-repository --repository-name backstage --force

# Delete TechDocs S3 bucket
aws s3 rm s3://backstage-techdocs-${ACCOUNT_ID} --recursive
aws s3 rb s3://backstage-techdocs-${ACCOUNT_ID}

# Remove OIDC provider
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?ends_with(Arn, `token.actions.githubusercontent.com`)].Arn' \
  --output text)
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $OIDC_ARN
```

## Learning Objectives

After completing this project, you will understand:

- Internal Developer Platform design principles and the paved-road concept
- Self-service infrastructure benefits and developer experience metrics (DORA)
- Terraform module versioning with semantic version tags
- Backstage service catalog, software templates, and TechDocs
- Golden-path templates that enforce best practices at provisioning time
- Deploying Backstage to EKS using Helm
- GitHub OIDC integration for keyless CI/CD authentication
- Platform governance with Kubernetes RBAC

## Troubleshooting

- **Backstage pod CrashLoopBackOff**: Check `kubectl logs` for missing environment variables or misconfigured `app-config.yaml`
- **Terraform module not found**: Verify the Git tag format matches `modules/<name>/v<semver>`
- **TechDocs not rendering**: Ensure the S3 bucket policy allows Backstage to read objects and the `techdocs.publisher` config points to the correct bucket
- **GitHub OIDC errors**: Confirm the thumbprint and `client-id-list` match your AWS region's STS endpoint
