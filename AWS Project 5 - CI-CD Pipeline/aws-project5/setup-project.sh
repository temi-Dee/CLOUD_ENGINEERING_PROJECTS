#!/bin/bash
# Project 5: CI/CD Pipeline Setup Script
# Creates complete project structure with GitHub Actions

set -e

echo "🚀 Setting up CI/CD Pipeline Project..."

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Variables
PROJECT_DIR="my-app"
GITHUB_USERNAME="${1:-YOUR_GITHUB_USERNAME}"
REPO_NAME="${2:-my-app}"

if [ "$GITHUB_USERNAME" == "YOUR_GITHUB_USERNAME" ]; then
    echo -e "${YELLOW}Usage: ./setup-project.sh <github-username> <repo-name>${NC}"
    echo -e "${YELLOW}Example: ./setup-project.sh johndoe my-awesome-app${NC}"
    echo ""
    echo "Continuing with default values (you'll need to update them later)..."
fi

# Step 1: Create project directory
echo -e "${BLUE}Step 1: Creating project structure...${NC}"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Initialize Node.js project
npm init -y

# Install dependencies
npm install express
npm install --save-dev eslint jest supertest

# Create directories
mkdir -p src tests .github/workflows

echo -e "${GREEN}✓ Project structure created${NC}"

# Step 2: Create source files
echo -e "${BLUE}Step 2: Creating application files...${NC}"

cat > src/index.js << 'EOF'
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
    res.json({ 
        message: 'Hello from CI/CD Pipeline!',
        version: '1.0.0',
        timestamp: new Date().toISOString()
    });
});

app.get('/health', (req, res) => {
    res.json({ 
        status: 'healthy',
        uptime: process.uptime()
    });
});

app.get('/api/info', (req, res) => {
    res.json({
        environment: process.env.NODE_ENV || 'development',
        nodeVersion: process.version,
        platform: process.platform
    });
});

const server = app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});

module.exports = { app, server };
EOF

cat > tests/index.test.js << 'EOF'
const request = require('supertest');
const { app, server } = require('../src/index');

describe('API Tests', () => {
    afterAll(() => {
        server.close();
    });

    test('GET / should return welcome message', async () => {
        const response = await request(app).get('/');
        expect(response.statusCode).toBe(200);
        expect(response.body.message).toBe('Hello from CI/CD Pipeline!');
        expect(response.body.version).toBe('1.0.0');
    });

    test('GET /health should return healthy status', async () => {
        const response = await request(app).get('/health');
        expect(response.statusCode).toBe(200);
        expect(response.body.status).toBe('healthy');
        expect(response.body.uptime).toBeGreaterThanOrEqual(0);
    });

    test('GET /api/info should return system information', async () => {
        const response = await request(app).get('/api/info');
        expect(response.statusCode).toBe(200);
        expect(response.body).toHaveProperty('nodeVersion');
        expect(response.body).toHaveProperty('platform');
    });
});
EOF

# Update package.json
cat > package.json << 'EOF'
{
  "name": "my-app",
  "version": "1.0.0",
  "description": "Sample app for CI/CD pipeline with GitHub Actions",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node src/index.js",
    "test": "jest --coverage",
    "test:watch": "jest --watch",
    "lint": "eslint src/**/*.js tests/**/*.js",
    "lint:fix": "eslint src/**/*.js tests/**/*.js --fix"
  },
  "keywords": ["cicd", "github-actions", "aws"],
  "author": "",
  "license": "MIT",
  "dependencies": {
    "express": "^4.18.2"
  },
  "devDependencies": {
    "eslint": "^8.50.0",
    "jest": "^29.7.0",
    "supertest": "^6.3.3"
  },
  "jest": {
    "testEnvironment": "node",
    "coverageDirectory": "coverage",
    "collectCoverageFrom": [
      "src/**/*.js"
    ]
  }
}
EOF

# Create ESLint config
cat > .eslintrc.json << 'EOF'
{
  "env": {
    "node": true,
    "es2021": true,
    "jest": true
  },
  "extends": "eslint:recommended",
  "parserOptions": {
    "ecmaVersion": 12
  },
  "rules": {
    "indent": ["error", 4],
    "quotes": ["error", "single"],
    "semi": ["error", "always"],
    "no-unused-vars": ["error", { "argsIgnorePattern": "^_" }],
    "no-console": "off"
  }
}
EOF

# Create .gitignore
cat > .gitignore << 'EOF'
node_modules/
coverage/
dist/
*.log
.env
.DS_Store
EOF

echo -e "${GREEN}✓ Application files created${NC}"

# Step 3: Create GitHub Actions workflows
echo -e "${BLUE}Step 3: Creating GitHub Actions workflows...${NC}"

cat > .github/workflows/ci.yml << 'EOF'
name: CI Pipeline

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  lint:
    name: Lint Code
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run ESLint
        run: npm run lint

  test:
    name: Run Tests
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run tests with coverage
        run: npm test

      - name: Upload coverage reports
        uses: actions/upload-artifact@v3
        with:
          name: coverage-report
          path: coverage/
          retention-days: 30

  build:
    name: Build Application
    runs-on: ubuntu-latest
    needs: test
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Build application
        run: |
          mkdir -p dist
          cp -r src/* dist/
          cp package*.json dist/
          echo "Build completed at $(date)" > dist/build-info.txt

      - name: Upload build artifacts
        uses: actions/upload-artifact@v3
        with:
          name: build-artifacts
          path: dist/
          retention-days: 30

  security-scan:
    name: Security Scan
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Run npm audit
        run: npm audit --audit-level=moderate
        continue-on-error: true
EOF

cat > .github/workflows/deploy.yml << 'EOF'
name: Deploy to AWS

on:
  push:
    branches: [ main ]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy-s3:
    name: Deploy to S3
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/GitHubActionsRole
          aws-region: us-east-1

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'

      - name: Install dependencies
        run: npm ci

      - name: Build for production
        run: |
          mkdir -p dist
          cp -r src/* dist/
          cp package*.json dist/
          echo "Deployed at $(date)" > dist/deployment-info.txt
          echo "Commit: ${{ github.sha }}" >> dist/deployment-info.txt

      - name: Deploy to S3
        run: |
          aws s3 sync dist/ s3://${{ secrets.S3_BUCKET_NAME }}/ --delete
          echo "Deployment completed successfully"

      - name: Invalidate CloudFront cache
        if: ${{ secrets.CLOUDFRONT_DISTRIBUTION_ID != '' }}
        run: |
          aws cloudfront create-invalidation \
            --distribution-id ${{ secrets.CLOUDFRONT_DISTRIBUTION_ID }} \
            --paths "/*"

      - name: Deployment summary
        run: |
          echo "✅ Deployment completed"
          echo "📦 Bucket: ${{ secrets.S3_BUCKET_NAME }}"
          echo "🔗 Commit: ${{ github.sha }}"
          echo "👤 Actor: ${{ github.actor }}"

  deploy-elastic-beanstalk:
    name: Deploy to Elastic Beanstalk
    runs-on: ubuntu-latest
    if: false  # Set to true to enable EB deployment
    environment: production
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/GitHubActionsRole
          aws-region: us-east-1

      - name: Generate deployment package
        run: |
          zip -r deploy-${{ github.sha }}.zip . -x '*.git*' 'node_modules/*' 'coverage/*'

      - name: Upload to S3
        run: |
          aws s3 cp deploy-${{ github.sha }}.zip \
            s3://${{ secrets.EB_BUCKET_NAME }}/deploy-${{ github.sha }}.zip

      - name: Create application version
        run: |
          aws elasticbeanstalk create-application-version \
            --application-name my-app \
            --version-label ${{ github.sha }} \
            --source-bundle S3Bucket="${{ secrets.EB_BUCKET_NAME }}",S3Key="deploy-${{ github.sha }}.zip"

      - name: Deploy to environment
        run: |
          aws elasticbeanstalk update-environment \
            --application-name my-app \
            --environment-name my-app-env \
            --version-label ${{ github.sha }}
EOF

echo -e "${GREEN}✓ GitHub Actions workflows created${NC}"

# Step 4: Create README
cat > README.md << 'EOF'
# My App - CI/CD Pipeline Demo

A sample Node.js application demonstrating CI/CD with GitHub Actions and AWS.

## Features

- Express.js REST API
- Automated testing with Jest
- Code linting with ESLint
- CI/CD with GitHub Actions
- AWS deployment (S3 or Elastic Beanstalk)

## Local Development

```bash
# Install dependencies
npm install

# Run tests
npm test

# Run linter
npm run lint

# Start development server
npm run dev
```

## CI/CD Pipeline

### Continuous Integration
- Automated linting on every push
- Unit tests with coverage reports
- Security scanning with npm audit
- Build artifact generation

### Continuous Deployment
- Automatic deployment to AWS S3 on main branch
- Optional Elastic Beanstalk deployment
- CloudFront cache invalidation

## Setup Instructions

1. Fork this repository
2. Configure AWS OIDC provider
3. Add GitHub secrets:
   - `AWS_ACCOUNT_ID`
   - `S3_BUCKET_NAME`
   - `CLOUDFRONT_DISTRIBUTION_ID` (optional)
4. Push to main branch to trigger deployment

## API Endpoints

- `GET /` - Welcome message
- `GET /health` - Health check
- `GET /api/info` - System information

## License

MIT
EOF

echo -e "${GREEN}✓ README created${NC}"

# Step 5: Install dependencies
echo -e "${BLUE}Step 5: Installing dependencies...${NC}"
npm install
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Step 6: Run tests to verify setup
echo -e "${BLUE}Step 6: Running tests...${NC}"
npm test
echo -e "${GREEN}✓ Tests passed${NC}"

# Step 7: Initialize git
echo -e "${BLUE}Step 7: Initializing Git repository...${NC}"
git init
git add .
git commit -m "Initial commit: CI/CD pipeline with GitHub Actions"
echo -e "${GREEN}✓ Git repository initialized${NC}"

# Create setup instructions
cd ..
cat > SETUP_INSTRUCTIONS.txt << EOF
CI/CD Pipeline Project Setup Complete!
======================================

Project Location: ./$PROJECT_DIR

Next Steps:
-----------

1. Configure AWS OIDC Provider:
   cd $PROJECT_DIR
   ../configure-aws.sh

2. Create GitHub Repository:
   gh repo create $REPO_NAME --public --source=. --remote=origin
   
   Or manually:
   - Go to https://github.com/new
   - Create repository named: $REPO_NAME
   - Run: git remote add origin https://github.com/$GITHUB_USERNAME/$REPO_NAME.git

3. Configure GitHub Secrets:
   gh secret set AWS_ACCOUNT_ID --body "YOUR_AWS_ACCOUNT_ID"
   gh secret set S3_BUCKET_NAME --body "YOUR_S3_BUCKET_NAME"
   gh secret set CLOUDFRONT_DISTRIBUTION_ID --body "YOUR_CF_DIST_ID"

4. Push to GitHub:
   git branch -M main
   git push -u origin main

5. Monitor Pipeline:
   gh run list
   gh run watch

Local Testing:
--------------
cd $PROJECT_DIR
npm test          # Run tests
npm run lint      # Run linter
npm start         # Start server (http://localhost:3000)

Files Created:
--------------
✓ src/index.js - Express application
✓ tests/index.test.js - Jest tests
✓ .github/workflows/ci.yml - CI pipeline
✓ .github/workflows/deploy.yml - Deployment pipeline
✓ package.json - Dependencies and scripts
✓ .eslintrc.json - Linting configuration
✓ README.md - Project documentation

AWS Resources Needed:
---------------------
- OIDC Provider for GitHub Actions
- IAM Role: GitHubActionsRole
- S3 Bucket for deployment
- CloudFront Distribution (optional)
- Elastic Beanstalk (optional)

Run ../configure-aws.sh to set up AWS resources automatically.
EOF

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Project Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Project created in: ${BLUE}./$PROJECT_DIR${NC}"
echo ""
echo "Next steps:"
echo "1. cd $PROJECT_DIR"
echo "2. Review SETUP_INSTRUCTIONS.txt"
echo "3. Run ../configure-aws.sh to set up AWS resources"
echo "4. Create GitHub repository and push code"
echo ""
