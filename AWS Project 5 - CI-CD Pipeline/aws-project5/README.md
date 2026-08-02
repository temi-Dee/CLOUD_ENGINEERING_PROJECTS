# Project 5: CI/CD Pipeline with GitHub Actions

## Overview

Your development team needs an automated pipeline that tests code on every commit and deploys successful builds to production. Instead of manually running tests and deployments, you will implement a CI/CD pipeline using GitHub Actions that automatically lints, tests, and deploys your application to AWS with zero manual intervention.

## Prerequisites

Before starting this project, ensure you have:

1. A GitHub account and a GitHub repository
2. An AWS account with IAM, S3, and optionally Elastic Beanstalk permissions
3. Node.js and npm installed locally
4. AWS CLI installed and configured
5. Git installed for version control
6. GitHub CLI (`gh`) installed (optional, for secret management)
7. Basic understanding of YAML syntax and testing frameworks (Jest recommended)

## Project Structure

```
AWS Project 5 - CI-CD Pipeline/
├── .github/
│   └── workflows/
│       └── ci-cd.yml          # Combined CI and CD workflow
├── setup-project.sh           # Creates the sample Node.js app and workflows
├── configure-aws.sh           # Provisions AWS resources (OIDC, IAM, S3)
├── cleanup-aws.sh             # Tears down all AWS resources
└── README.md
```

After running `setup-project.sh`, a `my-app/` directory is created with this layout:

```
my-app/
├── .github/
│   └── workflows/
│       ├── ci.yml             # Build, lint, test pipeline
│       └── deploy.yml         # AWS deployment pipeline
├── src/
│   └── index.js               # Express application
├── tests/
│   └── index.test.js          # Jest unit tests
├── package.json
├── .eslintrc.json
└── .gitignore
```

## Steps

### 1. Create the Sample Application

Run `setup-project.sh` to scaffold the Node.js app, install dependencies, generate the GitHub Actions workflow files, and run a local test to verify everything works:

```bash
chmod +x setup-project.sh
./setup-project.sh <github-username> <repo-name>
# Example:
./setup-project.sh johndoe my-awesome-app
```

The script creates `my-app/` with an Express REST API, Jest tests, ESLint configuration, and both CI and deploy workflow files.

### 2. Provision AWS Resources

Run `configure-aws.sh` to create the IAM OIDC provider, IAM role for GitHub Actions, and an S3 bucket for deployment artifacts:

```bash
chmod +x configure-aws.sh
./configure-aws.sh <github-username> <repo-name>
# Example:
./configure-aws.sh johndoe my-awesome-app
```

The script:
- Creates an OIDC provider for `token.actions.githubusercontent.com`
- Creates the `GitHubActionsRole` IAM role with a trust policy scoped to your repository
- Attaches `AmazonS3FullAccess` and `CloudFrontFullAccess`
- Creates an S3 bucket and enables static website hosting
- Optionally creates a CloudFront distribution

All resource identifiers are saved to `aws-config.txt`.

### 3. Push Code to GitHub

Create a GitHub repository and push the project:

```bash
cd my-app

# Using GitHub CLI
gh repo create <repo-name> --public --source=. --remote=origin

# Or manually: create the repo on github.com, then:
# git remote add origin https://github.com/<username>/<repo-name>.git

git branch -M main
git push -u origin main
```

### 4. Configure GitHub Secrets

Add the AWS values as repository secrets so the workflow can authenticate:

```bash
# Using GitHub CLI (run from inside my-app/)
gh secret set AWS_ACCOUNT_ID --body "<your-account-id>"
gh secret set S3_BUCKET_NAME --body "<bucket-name-from-aws-config.txt>"

# Optional — if CloudFront was created:
gh secret set CLOUDFRONT_DISTRIBUTION_ID --body "<distribution-id>"
```

Alternatively, go to your repository on GitHub: Settings > Secrets and variables > Actions > New repository secret.

### 5. Monitor Pipeline Execution

After pushing to `main`, the workflow triggers automatically:

```bash
# List recent workflow runs
gh run list

# Stream logs for the latest run
gh run watch
```

You can also view runs in the Actions tab of your GitHub repository.

## CI/CD Workflow Overview

The `.github/workflows/ci-cd.yml` file in this project directory provides a minimal combined pipeline that:

1. Checks out the code
2. Installs and caches Node.js modules (if `my-app/package.json` exists)
3. Runs ESLint
4. Runs Jest tests
5. Validates the AWS CLI is available
6. On push to `main`: authenticates via OIDC and deploys to AWS

The `setup-project.sh` script generates separate `ci.yml` and `deploy.yml` files inside `my-app/` with more advanced stages (security scanning, build artifact upload, CloudFront invalidation, Elastic Beanstalk support).

## Testing the Pipeline Locally

Before pushing, verify the app works locally:

```bash
cd my-app
npm test       # Run Jest tests
npm run lint   # Run ESLint
npm start      # Start server on http://localhost:3000
```

Test the running server:

```bash
curl http://localhost:3000/
curl http://localhost:3000/health
curl http://localhost:3000/api/info
```

## Triggering a Deployment

```bash
cd my-app
echo "// Updated $(date)" >> src/index.js
git add src/index.js
git commit -m "Trigger CI/CD pipeline"
git push

gh run watch  # Monitor the workflow
```

After the deploy job completes, check the S3 bucket:

```bash
aws s3 ls s3://<bucket-name>/
```

## Console Deployment

### 1. Create IAM OIDC Provider for GitHub Actions

1. Go to **IAM → Identity providers → Add provider**
2. **Provider type:** OpenID Connect
3. **Provider URL:** `https://token.actions.githubusercontent.com` → click **Get thumbprint**
4. **Audience:** `sts.amazonaws.com` → click **Add provider**

### 2. Create IAM Role for GitHub Actions

1. Go to **IAM → Roles → Create role**
2. **Trusted entity type:** Web identity
3. **Identity provider:** `token.actions.githubusercontent.com` | **Audience:** `sts.amazonaws.com` → click **Next**
4. Attach **AmazonS3FullAccess** and **CloudFrontFullAccess** → click **Next**
5. **Role name:** `GitHubActionsRole` → click **Create role**
6. Open the role → **Trust relationships → Edit trust policy** and add a `Condition` to restrict to your repo:
   ```json
   "Condition": {
     "StringLike": {
       "token.actions.githubusercontent.com:sub": "repo:<your-github-username>/<your-repo-name>:*"
     }
   }
   ```
7. Click **Update policy**

### 3. Create S3 Bucket for Artifacts

1. Go to **S3 → Create bucket**
   - **Bucket name:** unique name e.g. `myapp-cicd-artifacts-12345` | **Region:** us-east-1
   - Uncheck **Block all public access** → acknowledge the warning
2. Click **Create bucket**
3. Open the bucket → **Properties → Static website hosting → Edit** → enable, **Index document:** `index.html` → **Save**
4. Go to **Permissions → Bucket policy** and add a public read policy replacing `YOUR_BUCKET_NAME`:
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::YOUR_BUCKET_NAME/*"}]}
   ```

### 4. Copy Your AWS Account ID

1. Click your account name in the top-right corner → **Account** → copy the 12-digit **Account ID**

### 5. Add Secrets to GitHub

1. Go to your GitHub repository → **Settings → Secrets and variables → Actions**
2. Click **New repository secret** and add:
   - **Name:** `AWS_ACCOUNT_ID` | **Value:** your 12-digit account ID
   - **Name:** `S3_BUCKET_NAME` | **Value:** your bucket name
3. Click **Add secret** for each

### 6. Push Code and Monitor

1. Commit and push your code to `main`:
   ```bash
   git add .
   git commit -m "Initial CI/CD setup"
   git push origin main
   ```
2. Go to your GitHub repository → **Actions** tab → watch the workflow run in real time
3. On success, open your S3 bucket in the AWS Console to confirm the deployed artifacts are present

### Console Cleanup

1. **S3** → open your bucket → select all objects → **Delete objects** → then **Delete bucket**
2. **IAM → Roles** → delete `GitHubActionsRole` (detach policies first)
3. **IAM → Identity providers** → delete `token.actions.githubusercontent.com`

---

## Cleanup

```bash
chmod +x cleanup-aws.sh
./cleanup-aws.sh
```

The script reads `aws-config.txt` and:
1. Disables and deletes the CloudFront distribution (if it was created)
2. Empties and deletes the S3 bucket
3. Detaches policies and deletes the `GitHubActionsRole` IAM role
4. Deletes the GitHub Actions OIDC provider

## Learning Objectives

After completing this project, you will understand:

- GitHub Actions workflow syntax and job structure
- Setting up CI/CD pipelines for continuous delivery
- Using IAM OIDC for keyless AWS authentication from GitHub Actions
- Implementing automated linting, testing, and security scanning in a pipeline
- Deploying application artifacts to Amazon S3
- Optionally distributing content via CloudFront
- Monitoring and troubleshooting failed workflow runs

## Troubleshooting

| Problem | Solution |
|---|---|
| OIDC authentication fails | Verify the trust policy contains the correct GitHub username and repository name |
| Tests fail in CI | Reproduce locally with `npm test`; check for environment-specific issues |
| Deployment fails | Confirm IAM role has S3 permissions and the `S3_BUCKET_NAME` secret is set |
| Workflow not triggering | Check the `on:` trigger branches match the branch you pushed to |
| CloudFront not updating | Add `CLOUDFRONT_DISTRIBUTION_ID` as a secret and re-run the deploy workflow |
