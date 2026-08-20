# Project 12: Kubernetes Cluster on EKS with Helm

## Overview

You want to leverage Kubernetes for container orchestration to manage complex multi-container applications with automatic scaling, self-healing, and rolling updates. AWS EKS manages the Kubernetes control plane for you, allowing you to focus on deploying applications. In this project you will provision an EKS cluster with managed node groups, deploy applications using Helm charts, configure Horizontal Pod Autoscaling (HPA), and set up the Cluster Autoscaler and AWS Load Balancer Controller.

## Prerequisites

- An AWS account with EKS, EC2, IAM, and CloudWatch permissions
- AWS CLI configured with credentials (`aws configure`)
- `eksctl`, `kubectl`, and `helm` installed (see Step 1)
- Basic understanding of Kubernetes concepts (Deployments, Services, Pods)
- Familiarity with YAML syntax

## Project Structure

```
AWS Project 12 - Kubernetes EKS/
├── README.md
├── cluster-config.yaml          # eksctl cluster definition
└── my-app/                      # Helm chart for the sample application
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        ├── hpa.yaml
        └── pdb.yaml
```

## Steps

### Step 1: Install Required Tools

```bash
# Install eksctl
curl --silent --location \
  "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
  | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
eksctl version
kubectl version --client
helm version
```

### Step 2: Create EKS Cluster

The cluster definition is in `cluster-config.yaml`. It provisions a managed node group (`general-workers`) with autoscaler and ALB ingress addon policies, enables the OIDC provider for IRSA, installs four managed addons (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver), and enables CloudWatch control-plane logging.

```bash
# Create cluster — this takes 15-20 minutes
eksctl create cluster -f cluster-config.yaml

# Update local kubeconfig
aws eks update-kubeconfig --name my-eks-cluster --region us-east-1

# Verify nodes are Ready
kubectl get nodes
kubectl get pods --all-namespaces
```

### Step 3: Set Up IRSA (IAM Roles for Service Accounts)

IRSA lets pods assume IAM roles without storing credentials. The OIDC provider is already enabled by `cluster-config.yaml` (`withOIDC: true`).

```bash
# Create an IAM policy granting S3 access
cat > s3-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::my-app-bucket",
      "arn:aws:s3:::my-app-bucket/*"
    ]
  }]
}
EOF

aws iam create-policy \
  --policy-name EKS-S3-Access \
  --policy-document file://s3-policy.json

# Create service account with the policy attached
eksctl create iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace default \
  --name s3-access-sa \
  --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/EKS-S3-Access \
  --approve \
  --override-existing-serviceaccounts

# Verify the annotation is present
kubectl describe serviceaccount s3-access-sa
```

### Step 4: Install AWS Load Balancer Controller

```bash
# Download and create the ALB controller IAM policy
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Create service account for the controller
eksctl create iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Step 5: Deploy the Sample Application with Helm

The `my-app/` Helm chart in this repository deploys an nginx application with a ClusterIP Service, HPA (cpu-based autoscaling), and PodDisruptionBudget.

```bash
# Install the chart into the production namespace
helm install my-app ./my-app \
  --namespace production \
  --create-namespace

# Check rollout status
kubectl rollout status deployment/my-app -n production
kubectl get all -n production
```

### Step 6: Configure the Horizontal Pod Autoscaler

The HPA is defined in `my-app/templates/hpa.yaml` and enabled via `values.yaml` (`autoscaling.enabled: true`). Metrics Server must be running for the HPA to function.

```bash
# Install Metrics Server if not already present
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify the HPA was created by the Helm chart
kubectl get hpa -n production
kubectl describe hpa my-app -n production

# View current resource usage
kubectl top pods -n production
```

### Step 7: Install the Cluster Autoscaler

The Cluster Autoscaler adds or removes EC2 nodes based on pending pod demand.

```bash
# Create the autoscaler IAM policy
cat > cluster-autoscaler-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam create-policy \
  --policy-name ClusterAutoscalerPolicy \
  --policy-document file://cluster-autoscaler-policy.json

eksctl create iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace kube-system \
  --name cluster-autoscaler \
  --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/ClusterAutoscalerPolicy \
  --approve

# Deploy via Helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=my-eks-cluster \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler
```

### Step 8: Apply Pod Security Standards

```bash
# Enforce the restricted Pod Security Standard on the production namespace
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### Step 9: Upgrade the Application with Helm

```bash
# Upgrade to a newer nginx image
helm upgrade my-app ./my-app \
  --namespace production \
  --set image.tag=1.26 \
  --atomic \
  --timeout 5m

# View release history
helm history my-app --namespace production

# Rollback to the previous release if needed
helm rollback my-app 1 --namespace production
```

## Console Deployment

> **Note:** EKS heavily requires `eksctl`, `kubectl`, and `helm`. The console steps below cover creating the EKS cluster and IAM resources via the AWS Console. You still need the CLI tools to configure `kubectl` and deploy workloads.

### 1. Create EKS Cluster via Console

1. Go to **EKS → Add cluster → Create**
   - **Name:** `my-eks-cluster` | **Kubernetes version:** 1.29
   - **Cluster service role:** click **Create recommended role** (creates `AmazonEKSClusterRole` automatically) → **Next**
2. **Networking:** select your VPC and at least 2 subnets in different AZs | **Cluster endpoint access:** Public → **Next**
3. **Logging:** enable **API server**, **Audit**, **Authenticator** → **Next**
4. Review and click **Create** — takes 10–15 minutes

### 2. Create Managed Node Group

1. Open the cluster → **Compute → Add node group**
   - **Name:** `general-workers` | **Node IAM role:** click **Create recommended role** → **Next**
   - **AMI type:** Amazon Linux 2 | **Instance type:** `t3.medium` | **Disk:** 20 GiB
   - **Min:** 2 | **Max:** 5 | **Desired:** 2 → **Next**
2. Select your subnets → **Next → Create**

### 3. Configure kubectl

After the cluster is Active, run:

```bash
aws eks update-kubeconfig --name my-eks-cluster --region us-east-1
kubectl get nodes
```

### 4. Create IAM Policies for Add-ons (Console)

1. Go to **IAM → Policies → Create policy**
2. Create `AWSLoadBalancerControllerIAMPolicy` — paste the JSON from the CLI section (Step 4)
3. Create `ClusterAutoscalerPolicy` — paste the JSON from Step 7
4. Create `EKS-S3-Access` — paste the JSON from Step 3

### 5. Enable OIDC Provider

1. Go to **EKS → my-eks-cluster → Configuration → Details**
2. Copy the **OpenID Connect provider URL**
3. Go to **IAM → Identity providers → Add provider**
   - **Provider type:** OpenID Connect | paste the URL → **Get thumbprint**
   - **Audience:** `sts.amazonaws.com` → **Add provider**

### 6. Install Add-ons via Console (Optional)

1. Go to **EKS → my-eks-cluster → Add-ons → Get more add-ons**
2. Select **Amazon VPC CNI**, **CoreDNS**, **kube-proxy**, **Amazon EBS CSI Driver**
3. Follow the prompts to install each with the latest version

### 7. Deploy Workloads (requires kubectl)

With `kubectl` configured, install Helm charts per Steps 4–9 in the CLI section:

```bash
helm install my-app ./my-app --namespace production --create-namespace
kubectl get all -n production
```

### Console Cleanup

1. **EKS → my-eks-cluster → Compute** → delete node groups first
2. **EKS** → delete the cluster
3. **IAM → Policies** → delete `AWSLoadBalancerControllerIAMPolicy`, `ClusterAutoscalerPolicy`, `EKS-S3-Access`
4. **IAM → Identity providers** → delete the cluster OIDC provider

---

## CLI / Automation Reference

```bash
# Install Prometheus and Grafana for cluster monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123

# Access Grafana locally
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

# View node and pod resource usage
kubectl top nodes
kubectl top pods -n production
```

## Cleanup

```bash
# Uninstall Helm releases
helm uninstall my-app -n production
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall cluster-autoscaler -n kube-system
helm uninstall kube-prometheus-stack -n monitoring

# Delete namespaces
kubectl delete namespace production monitoring

# Delete EKS cluster — takes 10-15 minutes
eksctl delete cluster --name my-eks-cluster --region us-east-1

# Delete IAM policies
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/EKS-S3-Access
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/ClusterAutoscalerPolicy
```

## Testing / Validation

1. After `eksctl create cluster`, run `kubectl get nodes` and confirm all nodes show `Ready`.
2. After `helm install my-app`, run `kubectl get pods -n production` and confirm the expected number of pods are `Running`.
3. After installing Metrics Server, run `kubectl get hpa -n production` and confirm `TARGETS` shows a real CPU percentage (not `<unknown>`).
4. Scale a deployment manually to verify PodDisruptionBudget is respected: `kubectl scale deployment my-app -n production --replicas=1` should leave at least 1 pod running.

## Learning Objectives

After completing this project, you will understand:

- EKS cluster architecture and the role of managed node groups
- Deploying and managing Kubernetes workloads with Helm
- IRSA for pod-level IAM permissions without static credentials
- HPA scaling based on CPU and memory metrics
- Cluster Autoscaler for node-level scaling
- AWS Load Balancer Controller for ALB-backed Ingress resources
- Pod Disruption Budgets for safe rolling updates
- Pod Security Standards for namespace-level security enforcement

## Troubleshooting

- **Pods pending**: Check node capacity (`kubectl describe node`) and pod resource requests
- **IRSA not working**: Verify OIDC provider exists and the service account has the `eks.amazonaws.com/role-arn` annotation
- **HPA not scaling**: Confirm Metrics Server is running (`kubectl get pods -n kube-system | grep metrics-server`)
- **ALB not created**: Check ALB controller logs (`kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`) and IAM permissions
