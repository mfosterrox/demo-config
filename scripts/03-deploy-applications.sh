#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[APP-DEPLOY] ERROR:${NC} $1" >&2
    echo -e "${RED}[APP-DEPLOY] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Configuration
DEMO_LABEL="demo=roadshow"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"
log "Prerequisites validated successfully"

# Clone demo apps repository
log "Cloning demo apps repository..."
if [ ! -d "demo-apps" ]; then
    if ! git clone -b acs-demo-apps https://github.com/SeanRickerd/demo-apps demo-apps; then
        error "Failed to clone demo-apps repository. Check network connectivity and repository access."
    fi
    log "✓ Demo apps repository cloned successfully"
else
    log "Demo apps repository already exists, skipping clone"
fi

# Set TUTORIAL_HOME environment variable
log "Setting TUTORIAL_HOME environment variable..."
TUTORIAL_HOME="$(pwd)/demo-apps"
if [ ! -d "$TUTORIAL_HOME" ]; then
    error "TUTORIAL_HOME directory does not exist: $TUTORIAL_HOME"
fi
sed -i '/^export TUTORIAL_HOME=/d' ~/.bashrc
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "✓ TUTORIAL_HOME set to: $TUTORIAL_HOME"

# Load environment variables from ~/.bashrc
log "Loading environment variables from ~/.bashrc..."
if [ -f ~/.bashrc ]; then
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    # Source bashrc with error handling
    set +u  # Temporarily disable unbound variable checking
    if source ~/.bashrc; then
        log "Environment variables loaded"
    else
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    warning "~/.bashrc not found"
fi

# Get ACS Central Address from environment or oc command
log "Getting ACS Central Address..."
ACS_NAMESPACE="tssc-acs"

if [ -n "$ROX_ENDPOINT" ]; then
    ACS_CENTRAL_ADDRESS="$ROX_ENDPOINT"
    log "ACS Central Address from environment: $ACS_CENTRAL_ADDRESS"
else
    log "ROX_ENDPOINT not set, retrieving from OpenShift route..."
    if ! oc get ns "$ACS_NAMESPACE"; then
        error "Namespace '$ACS_NAMESPACE' not found. Check namespace: oc get namespace $ACS_NAMESPACE"
    fi

    if ! oc -n "$ACS_NAMESPACE" get route central; then
        error "ACS route 'central' not found in namespace '$ACS_NAMESPACE'. Check route: oc get route -n $ACS_NAMESPACE"
    fi

    ACS_CENTRAL_ADDRESS=$(oc -n "$ACS_NAMESPACE" get route central -o jsonpath='{.spec.host}:443')

    if [ -z "$ACS_CENTRAL_ADDRESS" ]; then
        error "Unable to determine ACS Central Address from route. Route exists but host is empty."
    fi
    log "✓ ACS Central Address from oc command (namespace: $ACS_NAMESPACE): $ACS_CENTRAL_ADDRESS"
fi

# Check if API token is available
if [ -z "$ROX_API_TOKEN" ]; then
    error "ROX_API_TOKEN not found in environment. Please ensure ROX_API_TOKEN is set in ~/.bashrc"
fi
log "✓ ROX_API_TOKEN found in environment"

# Deploy applications
log "Deploying applications from $TUTORIAL_HOME..."

# Deploy kubernetes-manifests
if [ -d "$TUTORIAL_HOME/kubernetes-manifests" ]; then
    log "Deploying kubernetes-manifests..."
    if ! oc apply -f "$TUTORIAL_HOME/kubernetes-manifests/" --recursive; then
        error "Failed to deploy kubernetes-manifests. Check manifests: ls -la $TUTORIAL_HOME/kubernetes-manifests/"
    fi
    log "✓ kubernetes-manifests deployed successfully"
else
    error "kubernetes-manifests directory not found at: $TUTORIAL_HOME/kubernetes-manifests"
fi

# Deploy skupper-demo
if [ -d "$TUTORIAL_HOME/skupper-demo" ]; then
    log "Deploying skupper-demo..."
    if ! oc apply -f "$TUTORIAL_HOME/skupper-demo/" --recursive; then
        error "Failed to deploy skupper-demo. Check manifests: ls -la $TUTORIAL_HOME/skupper-demo/"
    fi
    log "✓ skupper-demo deployed successfully"
else
    error "skupper-demo directory not found at: $TUTORIAL_HOME/skupper-demo"
fi

# Wait for deployments to be ready
log "Waiting for deployments to be ready..."

# Get all deployments with demo=roadshow label
log "Checking deployments with label $DEMO_LABEL..."
DEPLOYMENTS_OUTPUT=$(oc get deployments -l "$DEMO_LABEL" -A 2>&1)
if [ $? -ne 0 ]; then
    error "Failed to get deployments with label $DEMO_LABEL. Error: $DEPLOYMENTS_OUTPUT"
fi
if [ -z "$DEPLOYMENTS_OUTPUT" ] || echo "$DEPLOYMENTS_OUTPUT" | grep -q "No resources found"; then
    error "No deployments found with label $DEMO_LABEL. Check if applications were deployed correctly."
fi
echo "$DEPLOYMENTS_OUTPUT"

# Wait for each deployment to be available
log "Waiting for deployments to be available..."
NAMESPACES=$(oc get deployments -l "$DEMO_LABEL" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
if [ -z "$NAMESPACES" ]; then
    error "No namespaces found with deployments labeled $DEMO_LABEL"
fi

for namespace in $NAMESPACES; do
    log "Waiting for deployments in namespace: $namespace"
    
    # Get deployment names in this namespace
    deployments=$(oc get deployments -l "$DEMO_LABEL" -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ -z "$deployments" ]; then
        error "No deployments found in namespace $namespace with label $DEMO_LABEL"
    fi
    
    for deployment in $deployments; do
        log "Waiting for deployment: $deployment in namespace: $namespace"
        if ! oc wait --for=condition=Available deployment/"$deployment" -n "$namespace" --timeout=300s; then
            DEPLOYMENT_STATUS=$(oc get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' || echo "unknown")
            error "Deployment $deployment in namespace $namespace failed to become Available after 5 minutes. Status: $DEPLOYMENT_STATUS. Check: oc describe deployment $deployment -n $namespace"
        fi
        log "✓ Deployment $deployment in namespace $namespace is Available"
    done
done

# Verify deployments are running
log "Verifying deployments are running..."
if ! kubectl get deployments -l "$DEMO_LABEL" -A; then
    error "Failed to verify deployments. Check deployments: kubectl get deployments -l $DEMO_LABEL -A"
fi

# Check pod status
log "Checking pod status..."
PODS_OUTPUT=$(kubectl get pods -l "$DEMO_LABEL" -A)
if [ $? -ne 0 ]; then
    error "Failed to check pod status"
fi
echo "$PODS_OUTPUT"

# Verify all pods are running
NOT_RUNNING_PODS=$(echo "$PODS_OUTPUT" | grep -v "Running\|Completed\|NAME" | grep -v "^$" || true)
if [ -n "$NOT_RUNNING_PODS" ]; then
    warning "Some pods are not in Running or Completed state:"
    echo "$NOT_RUNNING_PODS"
fi

# Run roxctl scan on specific image
log "Running roxctl security scan on specific image..."

# Check if roxctl is available
if ! command -v roxctl >/dev/null 2>&1; then
    log "roxctl not found, installing to system location..."
    
    # Download roxctl to temporary location first
    if ! curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl"; then
        error "Failed to download roxctl from https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl. Check network connectivity."
    fi
    
    # Move to system-wide location
    if ! sudo mv /tmp/roxctl /usr/local/bin/roxctl; then
        error "Failed to move roxctl to /usr/local/bin/roxctl. Check sudo permissions."
    fi
    
    if ! sudo chmod +x /usr/local/bin/roxctl; then
        error "Failed to make roxctl executable"
    fi
    
    # Verify installation
    if ! command -v roxctl >/dev/null 2>&1; then
        error "roxctl installed but not found in PATH. Check installation: ls -la /usr/local/bin/roxctl"
    fi
    log "✓ roxctl installed successfully to /usr/local/bin/roxctl"
    ROXCTL_CMD="roxctl"
else
    log "roxctl already available in system PATH"
    ROXCTL_CMD="roxctl"
fi

# Verify ROX_ENDPOINT and ROX_API_TOKEN are set
if [ -z "$ROX_ENDPOINT" ]; then
    error "ROX_ENDPOINT not set. Please set it in ~/.bashrc"
fi
if [ -z "$ROX_API_TOKEN" ]; then
    error "ROX_API_TOKEN not set. Please set it in ~/.bashrc"
fi

# Scan specific image
SCAN_IMAGE="quay.io/mfoster/frontend:latest"
SCAN_TIMEOUT=30  # 30 seconds timeout
log "Scanning image: $SCAN_IMAGE (timeout: ${SCAN_TIMEOUT}s)"
SCAN_OUTPUT_FORMAT="json"
log "Running command: timeout $SCAN_TIMEOUT $ROXCTL_CMD --insecure-skip-tls-verify -e \"$ROX_ENDPOINT\" --token \"$ROX_API_TOKEN\" image scan --image \"$SCAN_IMAGE\" --force --output \"$SCAN_OUTPUT_FORMAT\""

SCAN_OUTPUT=$(timeout $SCAN_TIMEOUT $ROXCTL_CMD --insecure-skip-tls-verify -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" image scan --image "$SCAN_IMAGE" --force --output "$SCAN_OUTPUT_FORMAT" 2>&1)
SCAN_EXIT_CODE=$?

log "Scan output:"
echo "$SCAN_OUTPUT"

if [ $SCAN_EXIT_CODE -eq 124 ]; then
    error "Security scan timed out after ${SCAN_TIMEOUT}s for $SCAN_IMAGE. Increase timeout or check network connectivity."
elif [ $SCAN_EXIT_CODE -ne 0 ]; then
    error "Security scan failed for $SCAN_IMAGE (exit code: $SCAN_EXIT_CODE). Check ROX_ENDPOINT and ROX_API_TOKEN are correct."
fi
log "✓ Security scan completed successfully for $SCAN_IMAGE"

# roxctl is now installed permanently to /usr/local/bin/roxctl

# Final status
log "Application deployment completed successfully!"
log "========================================================="
log "Deployments with label $DEMO_LABEL:"
if ! kubectl get deployments -l "$DEMO_LABEL" -A; then
    error "Failed to retrieve final deployment status"
fi
log "========================================================="
log "Pods with label $DEMO_LABEL:"
if ! kubectl get pods -l "$DEMO_LABEL" -A; then
    error "Failed to retrieve final pod status"
fi
log "========================================================="
