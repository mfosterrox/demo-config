#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[APP-DEPLOY]${NC} $1"
    SCRIPT_FAILED=true
}

# Configuration
DEMO_LABEL="demo=roadshow"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

log "Prerequisites validated successfully"

# Clone demo apps repository
log "Cloning demo apps repository..."
if [ ! -d "demo-apps" ]; then
    git clone -b acs-demo-apps https://github.com/SeanRickerd/demo-apps demo-apps
    log "Demo apps repository cloned successfully"
else
    log "Demo apps repository already exists, skipping clone"
fi

# Set TUTORIAL_HOME environment variable
log "Setting TUTORIAL_HOME environment variable..."
TUTORIAL_HOME="$(pwd)/demo-apps"
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "TUTORIAL_HOME set to: $TUTORIAL_HOME"

# Load environment variables from ~/.bashrc
log "Loading environment variables from ~/.bashrc..."
if [ -f ~/.bashrc ]; then
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    # Source bashrc with error handling
    if source ~/.bashrc 2>/dev/null; then
        log "Environment variables loaded"
    else
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
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
    if ! oc get ns "$ACS_NAMESPACE" &>/dev/null || ! oc -n "$ACS_NAMESPACE" get route central &>/dev/null; then
        FALLBACK_NAMESPACE="stackrox"
        if oc get ns "$FALLBACK_NAMESPACE" &>/dev/null && oc -n "$FALLBACK_NAMESPACE" get route central &>/dev/null; then
            ACS_NAMESPACE="$FALLBACK_NAMESPACE"
            log "Default namespace tssc-acs does not contain ACS; using fallback namespace $ACS_NAMESPACE"
        else
            warning "ACS route 'central' not found in tssc-acs or rhacs-operator namespaces"
        fi
    fi

    ACS_CENTRAL_ADDRESS=$(oc -n "$ACS_NAMESPACE" get route central -o jsonpath='{.spec.host}{":443"}{"\n"}' 2>/dev/null || true)

    if [ -n "$ACS_CENTRAL_ADDRESS" ]; then
        log "ACS Central Address from oc command (namespace: $ACS_NAMESPACE): $ACS_CENTRAL_ADDRESS"
    else
        warning "Unable to determine ACS Central Address via oc command"
    fi
fi

# Check if API token is available
if [ -n "$ROX_API_TOKEN" ]; then
    log "ROX_API_TOKEN found in environment"
else
    warning "ROX_API_TOKEN not found in environment"
    log "Please ensure ROX_API_TOKEN is set in ~/.bashrc"
fi

# Deploy applications
log "Deploying applications from $TUTORIAL_HOME..."

# Deploy kubernetes-manifests
if [ -d "$TUTORIAL_HOME/kubernetes-manifests" ]; then
    log "Deploying kubernetes-manifests..."
    oc apply -f "$TUTORIAL_HOME/kubernetes-manifests/" --recursive
else
    warning "kubernetes-manifests directory not found, skipping..."
fi

# Deploy skupper-demo
if [ -d "$TUTORIAL_HOME/skupper-demo" ]; then
    log "Deploying skupper-demo..."
    oc apply -f "$TUTORIAL_HOME/skupper-demo/" --recursive
else
    warning "skupper-demo directory not found, skipping..."
fi

# Wait for deployments to be ready
log "Waiting for deployments to be ready..."

# Get all deployments with demo=roadshow label
log "Checking deployments with label $DEMO_LABEL..."
oc get deployments -l "$DEMO_LABEL" -A

# Wait for each deployment to be available
log "Waiting for deployments to be available..."
for namespace in $(oc get deployments -l "$DEMO_LABEL" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
    log "Waiting for deployments in namespace: $namespace"
    
    # Get deployment names in this namespace
    deployments=$(oc get deployments -l "$DEMO_LABEL" -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    
    for deployment in $deployments; do
        log "Waiting for deployment: $deployment in namespace: $namespace"
        oc wait --for=condition=Available deployment/"$deployment" -n "$namespace" --timeout=300s || warning "Timeout waiting for $deployment"
    done
done

# Verify deployments are running
log "Verifying deployments are running..."
kubectl get deployments -l "$DEMO_LABEL" -A

# Check pod status
log "Checking pod status..."
kubectl get pods -l "$DEMO_LABEL" -A

# Run roxctl scan on specific image
log "Running roxctl security scan on specific image..."

# Check if roxctl is available
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, installing to system location..."
    
    # Download roxctl to temporary location first
    curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl"
    
    if [ $? -eq 0 ]; then
        # Move to system-wide location
        sudo mv /tmp/roxctl /usr/local/bin/roxctl
        sudo chmod +x /usr/local/bin/roxctl
        
        # Verify installation
        if command -v roxctl &>/dev/null; then
            log "✓ roxctl installed successfully to /usr/local/bin/roxctl"
            ROXCTL_CMD="roxctl"
        else
            error "Failed to install roxctl to system location"
        fi
    else
        error "Failed to download roxctl"
    fi
else
    log "roxctl already available in system PATH"
    ROXCTL_CMD="roxctl"
fi

# Check if ROX_ENDPOINT and ROX_API_TOKEN are set
if [ -z "$ROX_ENDPOINT" ] || [ -z "$ROX_API_TOKEN" ]; then
    warning "ROX_ENDPOINT or ROX_API_TOKEN not set, skipping security scan"
    warning "Please set these environment variables to run security scans"
else
    # Scan specific image
    SCAN_IMAGE="quay.io/mfoster/frontend:latest"
    log "Scanning image: $SCAN_IMAGE"
    SCAN_OUTPUT_FORMAT="table"
    if $ROXCTL_CMD --insecure-skip-tls-verify -e "$ROX_ENDPOINT" image scan --image "$SCAN_IMAGE" --force --output "$SCAN_OUTPUT_FORMAT"; then
        log "✓ Security scan completed for $SCAN_IMAGE"
    else
        warning "Security scan failed for $SCAN_IMAGE"
    fi
fi

# roxctl is now installed permanently to /usr/local/bin/roxctl

# Final status
if [ "$SCRIPT_FAILED" = true ]; then
    warning "Application deployment finished with errors. Review the log for issues."
else
    log "Application deployment completed!"
fi
log "========================================================="
log "Deployments with label $DEMO_LABEL:"
kubectl get deployments -l "$DEMO_LABEL" -A
log "========================================================="
log "Pods with label $DEMO_LABEL:"
kubectl get pods -l "$DEMO_LABEL" -A
log "========================================================="
