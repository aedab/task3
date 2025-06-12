#!/bin/bash
# build.sh - Build and deploy script

set -e

# Configuration
IMAGE_NAME="pod-monitor"
IMAGE_TAG="latest"
NAMESPACE="pod-monitor"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "docker is not installed or not in PATH"
        exit 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # Check if Slack webhook URL is provided
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        log_error "SLACK_WEBHOOK_URL environment variable is not set"
        log_info "Please set it with: export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'"
        exit 1
    fi
    
    log_info "Prerequisites check passed ✓"
}

build_image() {
    log_info "Building Docker image..."
    
    docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
    
    if [ $? -eq 0 ]; then
        log_info "Docker image built successfully ✓"
    else
        log_error "Failed to build Docker image"
        exit 1
    fi
}

load_image_to_cluster() {
    log_info "Loading image to cluster..."
    
    # Detect cluster type and load image accordingly
    if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' | grep -q "minikube"; then
        log_info "Detected minikube cluster"
        minikube image load ${IMAGE_NAME}:${IMAGE_TAG}
    elif kubectl get nodes -o jsonpath='{.items[0].metadata.name}' | grep -q "kind"; then
        log_info "Detected kind cluster"
        kind load docker-image ${IMAGE_NAME}:${IMAGE_TAG}
    else
        log_warn "Unknown cluster type. You may need to push the image to a registry."
        log_info "To push to a registry, run:"
        log_info "  docker tag ${IMAGE_NAME}:${IMAGE_TAG} your-registry/${IMAGE_NAME}:${IMAGE_TAG}"
        log_info "  docker push your-registry/${IMAGE_NAME}:${IMAGE_TAG}"
    fi
}

update_manifests() {
    log_info "Updating Kubernetes manifests with Slack webhook URL..."
    
    # Create temporary directory for manifests
    TEMP_DIR=$(mktemp -d)
    cp -r manifests/* $TEMP_DIR/
    
    # Update secret with actual webhook URL
    sed -i.bak "s|https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK|${SLACK_WEBHOOK_URL}|g" $TEMP_DIR/manifests.yaml
    
    echo $TEMP_DIR
}

deploy_operator() {
    log_info "Deploying Pod Monitor Operator..."
    
    # Update manifests with webhook URL
    MANIFEST_DIR=$(update_manifests)
    
    # Apply manifests
    kubectl apply -f $MANIFEST_DIR/manifests.yaml
    
    # Wait for deployment to be ready
    log_info "Waiting for deployment to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/pod-monitor -n ${NAMESPACE}
    
    # Clean up temporary files
    rm -rf $MANIFEST_DIR
    
    log_info "Deployment completed successfully ✓"
}

deploy_test_app() {
    log_info "Deploying test nginx application..."
    
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
  labels:
    app: nginx-test
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
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "64Mi"
            cpu: "50m"
EOF

    log_info "Test application deployed ✓"
}

show_status() {
    log_info "Checking deployment status..."
    
    echo ""
    echo "=== Pod Monitor Operator Status ==="
    kubectl get pods -n ${NAMESPACE} -l app=pod-monitor
    
    echo ""
    echo "=== Service Status ==="
    kubectl get svc -n ${NAMESPACE}
    
    echo ""
    echo "=== Test Application Status ==="
    kubectl get pods -n default -l app=nginx-test
    
    echo ""
    echo "=== Recent Operator Logs ==="
    kubectl logs -n ${NAMESPACE} -l app=pod-monitor --tail=10
}

run_tests() {
    log_info "Running integration tests..."
    
    # Scale test deployment to trigger events
    log_info "Scaling test deployment to trigger MODIFIED events..."
    kubectl scale deployment nginx-test --replicas=2 -n default
    sleep 5
    
    # Update test deployment to trigger more events
    log_info "Updating test deployment image..."
    kubectl set image deployment/nginx-test nginx=nginx:1.21 -n default
    sleep 5
    
    # Show recent logs
    log_info "Recent operator logs after tests:"
    kubectl logs -n ${NAMESPACE} -l app=pod-monitor --tail=20
}

cleanup() {
    log_info "Cleaning up resources..."
    
    # Delete test application
    kubectl delete deployment nginx-test -n default --ignore-not-found=true
    
    # Delete operator
    kubectl delete namespace ${NAMESPACE} --ignore-not-found=true
    
    log_info "Cleanup completed ✓"
}

helm_deploy() {
    log_info "Deploying using Helm..."
    
    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed or not in PATH"
        exit 1
    fi
    
    helm install pod-monitor ./helm-chart \
        --set slack.webhookUrl="${SLACK_WEBHOOK_URL}" \
        --set image.repository="${IMAGE_NAME}" \
        --set image.tag="${IMAGE_TAG}" \
        --namespace ${NAMESPACE} \
        --create-namespace
    
    log_info "Helm deployment completed ✓"
}

show_help() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  build     - Build Docker image"
    echo "  deploy    - Deploy operator to Kubernetes"
    echo "  helm      - Deploy using Helm chart"
    echo "  test      - Run integration tests"
    echo "  status    - Show deployment status"
    echo "  logs      - Show operator logs"
    echo "  cleanup   - Remove all resources"
    echo "  all       - Build and deploy (default)"
    echo "  help      - Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  SLACK_WEBHOOK_URL - Slack webhook URL (required)"
    echo "  IMAGE_NAME        - Docker image name (default: pod-monitor)"
    echo "  IMAGE_TAG         - Docker image tag (default: latest)"
    echo "  NAMESPACE         - Kubernetes namespace (default: pod-monitor)"
    echo ""
    echo "Examples:"
    echo "  export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'"
    echo "  $0 all"
    echo "  $0 build"
    echo "  $0 deploy"
    echo "  $0 helm"
}

# Main execution
case "${1:-all}" in
    "build")
        check_prerequisites
        build_image
        load_image_to_cluster
        ;;
    "deploy")
        check_prerequisites
        deploy_operator
        deploy_test_app
        show_status
        ;;
    "helm")
        check_prerequisites
        build_image
        load_image_to_cluster
        helm_deploy
        deploy_test_app
        show_status
        ;;
    "test")
        run_tests
        ;;
    "status")
        show_status
        ;;
    "logs")
        kubectl logs -n ${NAMESPACE} -l app=pod-monitor -f
        ;;
    "cleanup")
        cleanup
        ;;
    "all")
        check_prerequisites
        build_image
        load_image_to_cluster
        deploy_operator
        deploy_test_app
        show_status
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac