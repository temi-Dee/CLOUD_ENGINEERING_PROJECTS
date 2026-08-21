# Project 14: Full Observability Stack — Metrics, Logs, and Traces

## Overview

You need complete visibility into your microservices application to understand performance, diagnose issues, and optimize reliability. A modern observability stack covers three pillars: metrics (Prometheus + Grafana), logs (Loki + Promtail), and distributed traces (AWS X-Ray). In this project you will deploy each pillar on your EKS cluster, wire them together in unified Grafana dashboards, and define alerting rules tied to SLOs.

## Prerequisites

- A running EKS cluster from Project 12 with `kubectl` and `helm` configured
- The EKS cluster has IRSA enabled (eksctl `withOIDC: true`)
- Basic understanding of Prometheus metrics, log aggregation, and distributed tracing
- An AWS account ID available (`aws sts get-caller-identity --query Account --output text`)

## Project Structure

```
AWS Project 14 - Full Observability Stack/
├── README.md
├── prometheus-values.yaml   # kube-prometheus-stack Helm values
├── loki-values.yaml         # Loki Helm values (S3 backend, replace ACCOUNT_ID)
├── promtail-values.yaml     # Promtail Helm values (log shipper)
└── dashboard.json           # Grafana SLI/SLO dashboard definition
```

Before running the steps below, replace the `ACCOUNT_ID` placeholder in `loki-values.yaml` with your real AWS account ID:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/ACCOUNT_ID/$ACCOUNT_ID/g" loki-values.yaml
```

## Steps

### Step 1: Install Prometheus and Grafana

```bash
# Add Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# Install kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values prometheus-values.yaml \
  --timeout 10m

# Verify all pods are Running
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

### Step 2: Install Loki for Log Aggregation

Loki stores logs in S3. You must create the S3 bucket and an IRSA-backed service account before installing Loki.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create S3 bucket for log storage
aws s3 mb s3://loki-logs-$ACCOUNT_ID

# Create IAM policy for Loki S3 access
cat > loki-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ],
    "Resource": [
      "arn:aws:s3:::loki-logs-$ACCOUNT_ID",
      "arn:aws:s3:::loki-logs-$ACCOUNT_ID/*"
    ]
  }]
}
EOF

aws iam create-policy \
  --policy-name LokiS3Policy \
  --policy-document file://loki-s3-policy.json

# Create IRSA service account for Loki
eksctl create iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace monitoring \
  --name loki \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/LokiS3Policy \
  --approve

# Substitute account ID into values file then install
sed -i "s/ACCOUNT_ID/$ACCOUNT_ID/g" loki-values.yaml

helm install loki grafana/loki \
  --namespace monitoring \
  --values loki-values.yaml
```

### Step 3: Install Promtail (Log Shipper)

Promtail runs as a DaemonSet and ships container logs from each node to the Loki gateway.

```bash
helm install promtail grafana/promtail \
  --namespace monitoring \
  --values promtail-values.yaml

# Verify Promtail is running on every node
kubectl get daemonset promtail -n monitoring
```

### Step 4: Set Up AWS X-Ray for Distributed Tracing

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create IAM policy for X-Ray
cat > xray-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam create-policy \
  --policy-name XRayPolicy \
  --policy-document file://xray-policy.json

# Create IRSA service account for the X-Ray daemon
eksctl create iamserviceaccount \
  --cluster my-eks-cluster \
  --namespace monitoring \
  --name xray-daemon \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/XRayPolicy \
  --approve

# Deploy X-Ray daemon as a DaemonSet
cat > xray-daemon.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: xray-daemon
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: xray-daemon
  template:
    metadata:
      labels:
        app: xray-daemon
    spec:
      serviceAccountName: xray-daemon
      containers:
        - name: xray-daemon
          image: amazon/aws-xray-daemon:latest
          ports:
            - containerPort: 2000
              protocol: UDP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          env:
            - name: AWS_REGION
              value: us-east-1
---
apiVersion: v1
kind: Service
metadata:
  name: xray-service
  namespace: monitoring
spec:
  selector:
    app: xray-daemon
  ports:
    - port: 2000
      protocol: UDP
      targetPort: 2000
  clusterIP: None
EOF

kubectl apply -f xray-daemon.yaml
```

### Step 5: Configure Grafana Data Sources

```bash
# Port-forward Grafana to localhost
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &

# Add Loki as a data source via the Grafana API
curl -X POST "http://localhost:3000/api/datasources" \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d '{
    "name": "Loki",
    "type": "loki",
    "url": "http://loki-gateway.monitoring.svc.cluster.local",
    "access": "proxy",
    "isDefault": false
  }'
```

### Step 6: Import the SLI/SLO Dashboard

The `dashboard.json` file in this project defines panels for Availability, p99 Latency, Error Rate, and Request Rate.

```bash
# Import via Grafana API (port-forward must be running)
curl -X POST "http://localhost:3000/api/dashboards/db" \
  -H "Content-Type: application/json" \
  -u admin:admin123 \
  -d "{\"dashboard\": $(cat dashboard.json), \"overwrite\": true, \"folderId\": 0}"
```

### Step 7: Create Prometheus Alerting Rules

```bash
cat > prometheus-rules.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: application-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: availability
      interval: 30s
      rules:
        - alert: HighErrorRate
          expr: |
            sum(rate(http_requests_total{status_code=~"5.."}[5m]))
            / sum(rate(http_requests_total[5m])) > 0.01
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "High error rate detected"
            description: "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes"

        - alert: HighLatency
          expr: |
            histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High p99 latency"
            description: "p99 latency is {{ $value | humanizeDuration }}"

        - alert: PodCrashLooping
          expr: |
            rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod is crash looping"
            description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is restarting frequently"

        - alert: NodeHighCPU
          expr: |
            100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Node CPU usage is high"
            description: "Node {{ $labels.instance }} CPU usage is {{ $value }}%"
EOF

kubectl apply -f prometheus-rules.yaml
```

## Console Deployment

> **Note:** Prometheus, Grafana, and Loki are deployed via Helm into Kubernetes. The console steps below cover the AWS resource setup. Helm and kubectl are still required for workload deployment.

### 1. Create S3 Bucket for Loki Log Storage

1. Go to **S3 → Create bucket**
   - **Name:** `loki-logs-<your-account-id>` | block public access: ON
2. Click **Create bucket**

### 2. Create IAM Policy for Loki S3 Access

1. Go to **IAM → Policies → Create policy** → JSON:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{"Effect":"Allow","Action":["s3:ListBucket","s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::loki-logs-<account-id>","arn:aws:s3:::loki-logs-<account-id>/*"]}]
   }
   ```
   **Policy name:** `LokiS3Policy` → **Create**

### 3. Create IAM Policy for X-Ray

1. **IAM → Policies → Create policy** → JSON:
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["xray:PutTraceSegments","xray:PutTelemetryRecords","xray:GetSamplingRules","xray:GetSamplingTargets"],"Resource":"*"}]}
   ```
   **Policy name:** `XRayPolicy` → **Create**

### 4. Update `loki-values.yaml` with Your Account ID

Open `loki-values.yaml` and replace `ACCOUNT_ID` with your 12-digit AWS account ID (find it in the top-right corner of the console).

### 5. Install the Observability Stack (requires kubectl and Helm)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring

# Install Prometheus + Grafana
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --values prometheus-values.yaml --timeout 10m

# Create IRSA service accounts for Loki and X-Ray, then install Loki + Promtail
eksctl create iamserviceaccount --cluster my-eks-cluster --namespace monitoring --name loki \
  --attach-policy-arn arn:aws:iam::<account-id>:policy/LokiS3Policy --approve
helm install loki grafana/loki --namespace monitoring --values loki-values.yaml
helm install promtail grafana/promtail --namespace monitoring --values promtail-values.yaml
```

### 6. Access Grafana via Browser

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
```

Open `http://localhost:3000` — log in with `admin` / `admin123`.

### 7. Verify X-Ray Traces in AWS Console

1. Go to **AWS X-Ray → Service map** — after deploying instrumented apps, traces appear here
2. Click **Traces** to view individual request details and latency breakdowns

### 8. Import Dashboard and Apply Alerting Rules

```bash
# Import the SLI/SLO dashboard
curl -X POST "http://localhost:3000/api/dashboards/db" \
  -H "Content-Type: application/json" -u admin:admin123 \
  -d "{\"dashboard\": $(cat dashboard.json), \"overwrite\": true, \"folderId\": 0}"

# Apply Prometheus alerting rules
kubectl apply -f prometheus-rules.yaml
```

### Console Cleanup

1. **S3** → empty and delete `loki-logs-<account-id>`
2. **IAM → Policies** → delete `LokiS3Policy` and `XRayPolicy`
3. Run `helm uninstall kube-prometheus-stack loki promtail -n monitoring`
4. `kubectl delete namespace monitoring`

---

## CLI / Automation Reference

```bash
# Access all observability UIs via port-forward
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring &

echo "Grafana:      http://localhost:3000  (admin / admin123)"
echo "Prometheus:   http://localhost:9090"
echo "Alertmanager: http://localhost:9093"
```

## Cleanup

```bash
# Uninstall Helm releases
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall loki -n monitoring
helm uninstall promtail -n monitoring

# Delete X-Ray daemon
kubectl delete -f xray-daemon.yaml

# Delete Prometheus alerting rules
kubectl delete -f prometheus-rules.yaml

# Delete namespace
kubectl delete namespace monitoring

# Delete S3 bucket
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rm s3://loki-logs-$ACCOUNT_ID --recursive
aws s3 rb s3://loki-logs-$ACCOUNT_ID

# Delete IAM policies
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/LokiS3Policy
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/XRayPolicy
```

## Testing / Validation

1. After installation, run `kubectl get pods -n monitoring` and confirm all pods are `Running` or `Completed`.
2. Port-forward Grafana and log in at `http://localhost:3000` with `admin`/`admin123`. Confirm the Prometheus data source shows a green "Data source connected" status.
3. Add the Loki data source via the API and verify it also shows green in the Grafana UI.
4. Go to Explore in Grafana, select Loki, and run `{namespace="production"}` to confirm container logs are streaming.
5. Port-forward Prometheus and navigate to `http://localhost:9090/alerts` to confirm the `HighErrorRate` and `NodeHighCPU` rules are loaded.

## Learning Objectives

After completing this project, you will understand:

- The three pillars of observability: metrics, logs, and traces
- Deploying the kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter)
- Loki architecture and S3-backed log storage with IRSA
- Promtail DaemonSet log shipping
- AWS X-Ray daemon deployment and IRSA integration
- Creating Grafana data sources and importing dashboards via API
- Writing Prometheus alerting rules with PrometheusRule CRDs
- SLI/SLO design and dashboard panels for availability and latency

## Troubleshooting

- **Prometheus not scraping**: Check ServiceMonitor labels match the Prometheus `serviceMonitorSelector`
- **Loki not receiving logs**: Verify Promtail is running on all nodes (`kubectl get ds promtail -n monitoring`) and check its logs for connection errors
- **X-Ray traces missing**: Verify the daemon pod is running and the application sends traces to `xray-service.monitoring.svc.cluster.local:2000`
- **Grafana dashboards empty**: Confirm the Prometheus and Loki data sources are configured and returning data in the Explore view
