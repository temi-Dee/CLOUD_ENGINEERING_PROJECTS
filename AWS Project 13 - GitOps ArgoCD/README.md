# Project 13: GitOps with ArgoCD on EKS

## Overview

Manual deployments to Kubernetes are error-prone and difficult to audit. You want a system where your Git repository is the single source of truth, and deployments happen automatically whenever changes are pushed. In this project you will implement GitOps using ArgoCD, which continuously watches your Git repository and syncs desired state to your EKS cluster. You will use the App of Apps pattern to manage multiple applications from a single root ArgoCD Application.

## Prerequisites

- A running EKS cluster from Project 12 with `kubectl` and `helm` configured
- A GitHub account and a repository to store GitOps configurations (referred to as `gitops-apps` below)
- ArgoCD CLI installed (see Step 2)
- Basic understanding of GitOps principles and Helm charts

## Project Structure

```
AWS Project 13 - GitOps ArgoCD/
├── README.md
└── gitops-repo/
    ├── apps/                        # App of Apps root chart
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── frontend.yaml        # ArgoCD Application for frontend
    │       ├── backend.yaml         # ArgoCD Application for backend
    │       └── monitoring.yaml      # ArgoCD Application for monitoring stack
    ├── frontend/                    # Frontend Helm chart
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   ├── values-production.yaml
    │   └── templates/
    │       ├── deployment.yaml
    │       └── service.yaml
    └── backend/                     # Backend Helm chart
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── deployment.yaml
            └── service.yaml
```

The `gitops-repo/` directory represents the contents you push to your GitHub `gitops-apps` repository. Replace `YOUR_USERNAME` in all files with your actual GitHub username before committing.

## Steps

### Step 1: Set Up the GitOps Repository

```bash
# Create and clone your GitOps repository
gh repo create gitops-apps --public --clone
cd gitops-apps

# Copy the charts from this project's gitops-repo/ into the repository root
# Then replace the placeholder with your actual GitHub username
grep -r "YOUR_USERNAME" . --include="*.yaml" -l | \
  xargs sed -i 's|YOUR_USERNAME|<your-github-username>|g'

git add .
git commit -m "Initialize GitOps repository with App of Apps"
git push
cd ..
```

### Step 2: Install ArgoCD on EKS

```bash
# Create ArgoCD namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for the server to become available
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s

# Retrieve the initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD admin password: $ARGOCD_PASSWORD"

# Install ArgoCD CLI
curl -sSL -o argocd-linux-amd64 \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd
```

### Step 3: Expose the ArgoCD Server

```bash
# Option A: port-forward (quick, development only)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Option B: ALB Ingress (persistent URL)
cat > argocd-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
EOF

kubectl apply -f argocd-ingress.yaml

ARGOCD_URL=$(kubectl get ingress argocd-server-ingress -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ArgoCD URL: https://$ARGOCD_URL"
```

### Step 4: Connect the GitHub Repository to ArgoCD

```bash
# Log in via CLI (using port-forward address)
argocd login localhost:8080 \
  --username admin \
  --password $ARGOCD_PASSWORD \
  --insecure

# Add repository using HTTPS and a GitHub Personal Access Token
argocd repo add https://github.com/YOUR_USERNAME/gitops-apps \
  --username YOUR_USERNAME \
  --password YOUR_GITHUB_TOKEN

# Or add using SSH
argocd repo add git@github.com:YOUR_USERNAME/gitops-apps.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# Confirm the repository is connected
argocd repo list
```

### Step 5: Deploy the Root App of Apps

The `apps/` chart in the repository contains ArgoCD Application manifests for `frontend`, `backend`, and `monitoring`. When you create the root ArgoCD Application pointing at `apps/`, ArgoCD will automatically create child Applications for each of them.

```bash
argocd app create root-apps \
  --repo https://github.com/YOUR_USERNAME/gitops-apps \
  --path apps \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Sync the root application and all children
argocd app sync root-apps

# Watch sync progress
argocd app wait root-apps --sync

# List all applications managed by ArgoCD
argocd app list
```

### Step 6: Configure ArgoCD RBAC and Projects

```bash
# Create an ArgoCD project that restricts source repos and destinations
cat > argocd-project.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production applications
  sourceRepos:
    - https://github.com/YOUR_USERNAME/gitops-apps
  destinations:
    - namespace: production
      server: https://kubernetes.default.svc
    - namespace: monitoring
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: 'apps'
      kind: Deployment
    - group: ''
      kind: Service
    - group: 'networking.k8s.io'
      kind: Ingress
    - group: 'autoscaling'
      kind: HorizontalPodAutoscaler
  roles:
    - name: developer
      description: Read and sync access
      policies:
        - p, proj:production:developer, applications, get, production/*, allow
        - p, proj:production:developer, applications, sync, production/*, allow
      groups:
        - developers
    - name: admin
      description: Full admin access
      policies:
        - p, proj:production:admin, applications, *, production/*, allow
      groups:
        - admins
EOF

kubectl apply -f argocd-project.yaml

# Set default RBAC policy to read-only
kubectl patch configmap argocd-rbac-cm -n argocd --patch '{
  "data": {
    "policy.default": "role:readonly",
    "policy.csv": "g, admins, role:admin\ng, developers, role:readonly"
  }
}'
```

### Step 7: Set Up Automated Rollbacks

ArgoCD's `selfHeal: true` sync policy corrects drift automatically. For application-level rollbacks, use `argocd app rollback`:

```bash
# View sync history for the frontend application
argocd app history frontend

# Roll back frontend to the previous revision
argocd app rollback frontend 1

# Watch the rollback progress
argocd app wait frontend --sync --timeout 120
```

### Step 8: Enable Automated Image Updates

```bash
# Install ArgoCD Image Updater
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Annotate the frontend Application to track semver nginx updates
kubectl annotate application frontend -n argocd \
  argocd-image-updater.argoproj.io/image-list="nginx:nginx" \
  argocd-image-updater.argoproj.io/nginx.update-strategy="semver" \
  argocd-image-updater.argoproj.io/nginx.allow-tags="regexp:^1\.[0-9]+$" \
  argocd-image-updater.argoproj.io/write-back-method="git"
```

## Console Deployment

> **Note:** ArgoCD runs inside Kubernetes and requires `kubectl`, `helm`, and a running EKS cluster. The console steps below cover the AWS-side setup. The rest uses CLI tools.

### 1. Verify EKS Cluster (AWS Console)

1. Go to **EKS → Clusters** and confirm `my-eks-cluster` is Active with healthy nodes
2. If not yet created, follow Project 12's Console Deployment section first

### 2. Create GitHub Repository (GitHub UI)

1. Go to **github.com → New repository**
   - **Name:** `gitops-apps` | **Visibility:** Public → **Create repository**
2. Copy the repository contents from `gitops-repo/` in this project
3. Replace all `YOUR_USERNAME` placeholders with your GitHub username
4. Commit and push to the repository

### 3. Generate GitHub Personal Access Token (GitHub UI)

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token** → select scopes: `repo` (full)
3. Copy and save the token — you will use it in Step 4

### 4. Install ArgoCD (requires kubectl)

Configure kubectl first, then:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

### 5. Access ArgoCD UI (Browser)

1. Open `https://localhost:8080` in your browser
2. Log in: **Username:** `admin` | **Password:** the value of `$ARGOCD_PASSWORD`
3. Click **Settings → Repositories → Connect Repo**
   - **Type:** HTTPS | **URL:** `https://github.com/YOUR_USERNAME/gitops-apps`
   - **Username:** your GitHub username | **Password:** your personal access token
4. Click **Connect** and verify the repo shows green

### 6. Create Root Application in ArgoCD UI

1. In the ArgoCD UI, click **New App**
   - **Application name:** `root-apps`
   - **Project:** `default`
   - **Sync policy:** Automatic | enable **Prune** and **Self Heal**
   - **Repository URL:** your gitops-apps repo URL | **Path:** `apps`
   - **Cluster URL:** `https://kubernetes.default.svc` | **Namespace:** `argocd`
2. Click **Create** — ArgoCD will create child Applications for frontend, backend, and monitoring

### Console Cleanup

1. In ArgoCD UI → select `root-apps` → **Delete** with cascade option
2. **kubectl:** `kubectl delete namespace argocd production monitoring`
3. **EKS Console:** delete cluster if no longer needed (see Project 12 cleanup)

---

## CLI / Automation Reference

### Testing the GitOps Workflow

```bash
# Update the frontend image tag in Git and push
sed -i 's/tag: "1.25"/tag: "1.26"/' frontend/values.yaml
git add frontend/values.yaml
git commit -m "Update frontend to nginx 1.26"
git push

# ArgoCD picks up the change automatically; watch it sync
argocd app wait frontend --sync --timeout 120

# Verify the new pods are running
kubectl get pods -n production -l app=frontend
```

### Testing Drift Detection

```bash
# Manually scale the frontend deployment (simulating drift)
kubectl scale deployment frontend -n production --replicas=5

# ArgoCD detects the drift and reverts within seconds (selfHeal: true)
watch kubectl get deployment frontend -n production
```

### Useful Monitoring Commands

```bash
# View application status summary
argocd app get frontend

# Follow application logs
argocd app logs frontend

# Get Kubernetes events for the production namespace
kubectl get events -n production --sort-by='.lastTimestamp'
```

## Cleanup

```bash
# Delete all managed applications (cascade deletes Kubernetes resources)
argocd app delete root-apps --cascade

# Uninstall ArgoCD
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd production monitoring
```

## Learning Objectives

After completing this project, you will understand:

- GitOps principles: Git as the single source of truth for cluster state
- ArgoCD architecture: Application Controller, Repo Server, API Server, and Dex
- App of Apps pattern for managing multiple applications from one root
- Automated sync, pruning, and self-healing to maintain desired state
- ArgoCD Projects for RBAC and resource restrictions
- Drift detection and automated correction with `selfHeal`
- Automated image updates with ArgoCD Image Updater
- Safe rollbacks using ArgoCD revision history

## Troubleshooting

- **App out of sync**: Check the ArgoCD UI diff view or run `argocd app diff frontend`
- **Sync failed**: Run `argocd app get frontend` and review the conditions and events sections
- **RBAC issues**: Verify project policies with `argocd proj get production` and group memberships
- **Image updater not working**: Check logs with `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater`
