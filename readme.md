# Kubernetes Pod Monitor Operator

A Kubernetes operator that monitors pod lifecycle events and sends notifications to Slack when pods are created, modified, or deleted.

## Features

- **Pod Lifecycle Monitoring**: Watches for pod creation, modification, and deletion events
- **Slack Notifications**: Sends formatted messages to Slack webhook
- **High Availability**: Runs with 2 replicas with rolling update strategy
- **RBAC Compliant**: Uses dedicated service account with minimal required permissions
- **Health Checks**: Includes readiness and liveness probes
- **NodePort Service**: Exposes service on port 30080 for external access

## Prerequisites

- Kubernetes cluster (1.20+)
- kubectl configured to access your cluster
- Docker for building the image
- Slack webhook URL for notifications
- (Optional) Helm 3.x for Helm deployment

## Quick Start

### Option 1: Direct Kubernetes Manifests

1. **Clone the repository and build the Docker image:**
   ```bash
   git clone <repository-url>
   cd kubernetes-pod-monitor
   docker build -t pod-monitor:latest .
   ```

2. **Load image into your cluster (for local development):**
   ```bash
   # For minikube
   minikube image load pod-monitor:latest
   
   # For kind
   kind load docker-image pod-monitor:latest
   
   # For production, push to your registry
   docker tag pod-monitor:latest your-registry/pod-monitor:latest
   docker push your-registry/pod-monitor:latest
   ```

3. **Update the Slack webhook URL in the secret:**
   ```bash
   # Edit manifests/secret.yaml and replace with your webhook URL
   kubectl apply -f manifests/
   ```

4. **Deploy the operator:**
   ```bash
   kubectl apply -f manifests/
   ```

### Option 2: Helm Chart

1. **Install using Helm:**
   ```bash
   helm install pod-monitor ./helm-chart \
     --set slack.webhookUrl="https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK" \
     --set image.repository="pod-monitor" \
     --set image.tag="latest" \
     --namespace pod-monitor \
     --create-namespace
   ```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SLACK_WEBHOOK_URL` | Slack webhook URL for notifications | Required |
| `NAMESPACE` | Kubernetes namespace to monitor | `default` |

### Slack Webhook Setup

1. Go to your Slack workspace
2. Create a new app or use existing one
3. Enable Incoming Webhooks
4. Create a webhook for your desired channel
5. Copy the webhook URL and use it in the configuration

## Architecture

### Components

- **Pod Monitor Operator**: Python application that watches Kubernetes API for pod events
- **Service Account**: `pod-monitor-sa` with minimal RBAC permissions
- **ClusterRole**: Permissions to list, get, and watch pods and events
- **Deployment**: 2 replicas with rolling update strategy
- **Service**: NodePort service exposing the application on port 30080
- **Secret**: Stores the Slack webhook URL securely

### Notification Messages

The operator sends the following messages to Slack:

- **Pod Created**: `"Hello world from {pod_name}"`
- **Pod Modified**: `"Things have changed, {pod_name}"`
- **Pod Deleted**: `"Goodbye world from, {pod_name}"`

## Testing

### Deploy Test Application

Create a test nginx deployment to trigger notifications:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF
```

### Scale and Update Test

```bash
# Scale to trigger MODIFIED events
kubectl scale deployment nginx-test --replicas=3

# Update image to trigger MODIFIED events
kubectl set image deployment/nginx-test nginx=nginx:1.21

# Delete to trigger DELETED events
kubectl delete deployment nginx-test
```

### Check Logs

```bash
# View operator logs
kubectl logs -n pod-monitor -l app=pod-monitor -f

# Check service status
kubectl get pods -n pod-monitor
kubectl get svc -n pod-monitor
```

## Security Considerations

- Uses non-root user in container
- Minimal RBAC permissions (only pod read access)
- Secrets stored securely in Kubernetes Secret
- Resource limits applied to prevent resource exhaustion
- Health checks for container health monitoring

## Troubleshooting

### Common Issues

1. **Operator not starting**:
   - Check RBAC permissions: `kubectl auth can-i list pods --as=system:serviceaccount:pod-monitor:pod-monitor-sa`
   - Verify Slack webhook URL in secret

2. **No Slack notifications**:
   - Verify Slack webhook URL is correct
   - Check operator logs for errors
   - Test webhook URL manually with curl

3. **Image pull errors**:
   - Ensure image is available in cluster (minikube/kind) or registry
   - Check image pull policy and registry credentials

### Debug Commands

```bash
# Check operator status
kubectl get pods -n pod-monitor

# View logs
kubectl logs -n pod-monitor deployment/pod-monitor

# Check RBAC
kubectl auth can-i list pods --as=system:serviceaccount:pod-monitor:pod-monitor-sa

# Test service connectivity
kubectl port-forward -n pod-monitor svc/pod-monitor-service 8080:8080
curl http://localhost:8080/health
```

## Development

### Local Development

1. **Set up local environment**:
   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. **Set environment variables**:
   ```bash
   export SLACK_WEBHOOK_URL="your-webhook-url"
   export NAMESPACE="default"
   ```

3. **Run locally** (requires kubeconfig):
   ```bash
   python pod_monitor.py
   ```

### Building and Testing

```bash
# Build image
docker build -t pod-monitor:latest .

# Run tests (if you add them)
python -m pytest tests/

# Security scan
docker scan pod-monitor:latest
```
