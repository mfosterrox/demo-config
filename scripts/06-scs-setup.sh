#!/bin/bash
# RHACS Secured Cluster Services Setup Script
# Generates init bundle and creates SecuredCluster resource

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
    echo -e "${GREEN}[RHACS-SCS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-SCS]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-SCS] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-SCS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

log "Prerequisites validated successfully"

# RHACS operator namespace
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Ensure namespace exists
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Namespace '$RHACS_OPERATOR_NAMESPACE' does not exist. Please run the Central install script first."
fi
log "✓ Namespace '$RHACS_OPERATOR_NAMESPACE' exists"

# Get Central route endpoint
log ""
log "Retrieving Central endpoint..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found. Please ensure Central is installed and ready."
fi
CENTRAL_ENDPOINT="https://${CENTRAL_ROUTE}"
log "✓ Central endpoint: $CENTRAL_ENDPOINT"

# Get Central admin password from secret
log ""
log "Retrieving Central admin password..."
CENTRAL_PASSWORD_SECRET="central-htpasswd"
if ! oc get secret "$CENTRAL_PASSWORD_SECRET" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Secret '$CENTRAL_PASSWORD_SECRET' not found. Central may not be fully initialized yet."
fi

CENTRAL_PASSWORD=$(oc get secret "$CENTRAL_PASSWORD_SECRET" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [ -z "$CENTRAL_PASSWORD" ]; then
    error "Failed to retrieve admin password from secret '$CENTRAL_PASSWORD_SECRET'"
fi
log "✓ Admin password retrieved"

# Download and install roxctl if needed
log ""
log "Checking for roxctl CLI..."
ROXCTL_CMD=""
if command -v roxctl &>/dev/null; then
    ROXCTL_CMD="roxctl"
    log "✓ roxctl found in PATH"
else
    log "roxctl not found, downloading..."
    
    # Determine OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Map architecture
    case "$ARCH" in
        x86_64)
            ROXCTL_ARCH="amd64"
            ;;
        aarch64|arm64)
            ROXCTL_ARCH="arm64"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            ;;
    esac
    
    # Map OS
    case "$OS" in
        linux)
            ROXCTL_OS="Linux"
            ;;
        darwin)
            ROXCTL_OS="Darwin"
            ;;
        *)
            error "Unsupported OS: $OS"
            ;;
    esac
    
    # Get RHACS version from CSV
    RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
    if [ -z "$RHACS_VERSION" ]; then
        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
    fi
    
    # Download roxctl
    ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/${ROXCTL_OS}/roxctl"
    ROXCTL_TMP="/tmp/roxctl"
    
    log "Downloading roxctl from: $ROXCTL_URL"
    if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
        # Try latest if version-specific download fails
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${ROXCTL_OS}/roxctl"
        log "Retrying with latest version: $ROXCTL_URL"
        if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
            error "Failed to download roxctl. Please install it manually."
        fi
    fi
    
    chmod +x "$ROXCTL_TMP"
    ROXCTL_CMD="$ROXCTL_TMP"
    log "✓ roxctl downloaded to $ROXCTL_TMP"
fi

# Authenticate with Central and get API token
log ""
log "Authenticating with Central..."
ROX_API_TOKEN=""
AUTH_OUTPUT=$($ROXCTL_CMD central login --insecure-skip-tls-verify -e "$CENTRAL_ENDPOINT" -p "$CENTRAL_PASSWORD" 2>&1 || echo "")
if echo "$AUTH_OUTPUT" | grep -q "Successfully"; then
    log "✓ Authenticated with Central"
    # Extract token from roxctl config or environment
    ROX_API_TOKEN=$($ROXCTL_CMD central whoami --insecure-skip-tls-verify -e "$CENTRAL_ENDPOINT" --output json 2>/dev/null | grep -oE '"token":"[^"]+"' | cut -d'"' -f4 || echo "")
    if [ -z "$ROX_API_TOKEN" ]; then
        # Try to get from roxctl config file
        if [ -f "$HOME/.config/roxctl/config.yaml" ]; then
            ROX_API_TOKEN=$(grep -A1 "endpoint:" "$HOME/.config/roxctl/config.yaml" | grep "token:" | awk '{print $2}' || echo "")
        fi
    fi
else
    error "Failed to authenticate with Central: $AUTH_OUTPUT"
fi

if [ -z "$ROX_API_TOKEN" ]; then
    warning "Could not retrieve API token. Will attempt to generate init bundle without explicit token."
fi

# Generate init bundle
log ""
log "Generating init bundle for Secured Cluster..."
INIT_BUNDLE_NAME="cluster-init-bundle"
INIT_BUNDLE_DIR="/tmp/rhacs-init-bundle"
mkdir -p "$INIT_BUNDLE_DIR"

# Generate init bundle
if [ -n "$ROX_API_TOKEN" ]; then
    export ROX_API_TOKEN
    INIT_BUNDLE_OUTPUT=$($ROXCTL_CMD central init-bundles generate "$INIT_BUNDLE_NAME" \
        --insecure-skip-tls-verify \
        -e "$CENTRAL_ENDPOINT" \
        --output-secrets "$INIT_BUNDLE_DIR" 2>&1 || echo "")
else
    INIT_BUNDLE_OUTPUT=$($ROXCTL_CMD central init-bundles generate "$INIT_BUNDLE_NAME" \
        --insecure-skip-tls-verify \
        -e "$CENTRAL_ENDPOINT" \
        -p "$CENTRAL_PASSWORD" \
        --output-secrets "$INIT_BUNDLE_DIR" 2>&1 || echo "")
fi

if [ ! -f "$INIT_BUNDLE_DIR/cluster-init-secrets.yaml" ] && [ ! -f "$INIT_BUNDLE_DIR/${INIT_BUNDLE_NAME}-cluster-init-secrets.yaml" ]; then
    error "Failed to generate init bundle: $INIT_BUNDLE_OUTPUT"
fi

# Find the generated secrets file
INIT_BUNDLE_FILE=""
if [ -f "$INIT_BUNDLE_DIR/cluster-init-secrets.yaml" ]; then
    INIT_BUNDLE_FILE="$INIT_BUNDLE_DIR/cluster-init-secrets.yaml"
elif [ -f "$INIT_BUNDLE_DIR/${INIT_BUNDLE_NAME}-cluster-init-secrets.yaml" ]; then
    INIT_BUNDLE_FILE="$INIT_BUNDLE_DIR/${INIT_BUNDLE_NAME}-cluster-init-secrets.yaml"
else
    INIT_BUNDLE_FILE=$(find "$INIT_BUNDLE_DIR" -name "*cluster-init-secrets.yaml" | head -1)
fi

if [ -z "$INIT_BUNDLE_FILE" ] || [ ! -f "$INIT_BUNDLE_FILE" ]; then
    error "Init bundle secrets file not found in $INIT_BUNDLE_DIR"
fi

log "✓ Init bundle generated: $INIT_BUNDLE_FILE"

# Apply init bundle secrets
log ""
log "Applying init bundle secrets..."
oc apply -f "$INIT_BUNDLE_FILE" -n "$RHACS_OPERATOR_NAMESPACE" || error "Failed to apply init bundle secrets"
log "✓ Init bundle secrets applied"

# Create SecuredCluster resource
log ""
log "Creating SecuredCluster resource..."
SECURED_CLUSTER_NAME="rhacs-secured-cluster-services"

# Get cluster name
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(oc config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's/[^a-zA-Z0-9-]/-/g' || echo "local-cluster")
fi

# Check if SecuredCluster already exists
if oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    log "SecuredCluster resource '$SECURED_CLUSTER_NAME' already exists"
    
    # Verify it's configured correctly
    EXISTING_CLUSTER_NAME=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.clusterName}' 2>/dev/null || echo "")
    if [ "$EXISTING_CLUSTER_NAME" != "$CLUSTER_NAME" ]; then
        warning "Existing SecuredCluster has different cluster name: $EXISTING_CLUSTER_NAME"
    fi
    
    log "✓ SecuredCluster resource exists"
else
    log "Creating new SecuredCluster resource..."
    
    # Build SecuredCluster CR YAML
    SECURED_CLUSTER_YAML="apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: $SECURED_CLUSTER_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  clusterName: $CLUSTER_NAME
  centralEndpoint: $CENTRAL_ENDPOINT
  admissionControl:
    enabled: true
    enforceOnCreates: false
    enforceOnUpdates: false
    scanInline: false
  auditLogs:
    collection: Auto
  perNode:
    collector:
      collection: CORE_BPF
    taintToleration: TolerateTaints
  scanner:
    scannerComponent: Enabled
    analyzer:
      scaling:
        autoScaling: Enabled
        minReplicas: 2
        maxReplicas: 5"
    
    # Apply the SecuredCluster resource
    echo "$SECURED_CLUSTER_YAML" | oc apply -f - || error "Failed to create SecuredCluster resource"
    log "✓ SecuredCluster resource created"
fi

# Wait for SecuredCluster components to be ready
log ""
log "Waiting for SecuredCluster components to be ready..."
MAX_WAIT=600
WAIT_COUNT=0
SCS_READY=false

# Wait for sensor deployment
log "Waiting for sensor deployment..."
SENSOR_READY=false
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    SENSOR_DEPLOYMENT=$(oc get deployment -n "$RHACS_OPERATOR_NAMESPACE" -l app=sensor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$SENSOR_DEPLOYMENT" ]; then
        SENSOR_READY_REPLICAS=$(oc get deployment "$SENSOR_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        SENSOR_REPLICAS=$(oc get deployment "$SENSOR_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        
        if [ "$SENSOR_READY_REPLICAS" = "$SENSOR_REPLICAS" ] && [ "$SENSOR_REPLICAS" != "0" ]; then
            SENSOR_READY=true
            log "✓ Sensor deployment is ready ($SENSOR_READY_REPLICAS/$SENSOR_REPLICAS replicas)"
            break
        fi
    fi
    
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for sensor... (${WAIT_COUNT}s/${MAX_WAIT}s)"
        if [ -n "$SENSOR_DEPLOYMENT" ]; then
            DEPLOYMENT_STATUS=$(oc get deployment "$SENSOR_DEPLOYMENT" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "0/0")
            log "  Sensor: $SENSOR_DEPLOYMENT ($DEPLOYMENT_STATUS ready)"
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$SENSOR_READY" = false ]; then
    warning "Sensor deployment did not become ready within ${MAX_WAIT} seconds"
    oc get deployment -n "$RHACS_OPERATOR_NAMESPACE" -l app=sensor || true
else
    SCS_READY=true
fi

# Clean up temporary files
if [ -d "$INIT_BUNDLE_DIR" ]; then
    rm -rf "$INIT_BUNDLE_DIR"
fi

if [ "$SCS_READY" = true ]; then
    log ""
    log "========================================================="
    log "RHACS Secured Cluster Services Setup Completed!"
    log "========================================================="
    log "Namespace: $RHACS_OPERATOR_NAMESPACE"
    log "SecuredCluster Resource: $SECURED_CLUSTER_NAME"
    log "Cluster Name: $CLUSTER_NAME"
    log "Central Endpoint: $CENTRAL_ENDPOINT"
    log "========================================================="
    log ""
    log "Secured Cluster Services are now configured and ready."
    log ""
else
    warning "Some SecuredCluster components may not be fully ready."
    log "Check component status: oc get pods -n $RHACS_OPERATOR_NAMESPACE -l app=sensor"
fi

