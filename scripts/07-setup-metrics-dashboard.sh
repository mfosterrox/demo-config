#!/bin/bash
# Metrics Dashboard Setup Script
# Sets up Prometheus operator and metrics dashboard for RHACS

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[METRICS-DASHBOARD]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[METRICS-DASHBOARD]${NC} $1"
}

error() {
    echo -e "${RED}[METRICS-DASHBOARD] ERROR:${NC} $1" >&2
    echo -e "${RED}[METRICS-DASHBOARD] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Function to load variable from ~/.bashrc if it exists
load_from_bashrc() {
    local var_name="$1"
    
    # First check if variable is already set in environment
    local env_value=$(eval "echo \${${var_name}:-}")
    if [ -n "$env_value" ]; then
        export "${var_name}=${env_value}"
        echo "$env_value"
        return 0
    fi
    
    # Otherwise, try to load from ~/.bashrc
    if [ -f ~/.bashrc ] && grep -q "^export ${var_name}=" ~/.bashrc; then
        local var_line=$(grep "^export ${var_name}=" ~/.bashrc | head -1)
        local var_value=$(echo "$var_line" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        export "${var_name}=${var_value}"
        echo "$var_value"
    fi
}

# Load environment variables from ~/.bashrc (set by script 01)
log "Loading environment variables from ~/.bashrc..."

# Ensure ~/.bashrc exists
if [ ! -f ~/.bashrc ]; then
    error "~/.bashrc not found. Please run script 01-rhacs-setup.sh first to initialize environment variables."
fi

# Clean up any malformed source commands in bashrc
if grep -q "^source $" ~/.bashrc; then
    log "Cleaning up malformed source commands in ~/.bashrc..."
    sed -i '/^source $/d' ~/.bashrc
fi

# Load SCRIPT_DIR and PROJECT_ROOT (set by script 01)
SCRIPT_DIR=$(load_from_bashrc "SCRIPT_DIR")
PROJECT_ROOT=$(load_from_bashrc "PROJECT_ROOT")

# Load NAMESPACE (set by script 01, defaults to tssc-acs)
NAMESPACE=$(load_from_bashrc "NAMESPACE")
if [ -z "$NAMESPACE" ]; then
    NAMESPACE="tssc-acs"
    log "NAMESPACE not found in ~/.bashrc, using default: $NAMESPACE"
else
    log "✓ Loaded NAMESPACE from ~/.bashrc: $NAMESPACE"
fi

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! command -v oc >/dev/null 2>&1; then
    error "OpenShift CLI (oc) not found. Please install oc and ensure it's in your PATH."
fi

if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Verify RHACS namespace exists
if ! oc get ns "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Please ensure RHACS is installed."
fi
log "✓ Namespace '$NAMESPACE' exists"

# Step 1: Install Cluster Observability Operator
log "========================================================="
log "Step 1: Installing Cluster Observability Operator"
log "========================================================="

SUBSCRIPTION_NAMESPACE="openshift-operators"
SUBSCRIPTION_NAME="observability-operator"
SUBSCRIPTION_FILE="${SCRIPT_DIR}/../config-files/subscription-observability-operator.yaml"

# Check if subscription file exists
if [ ! -f "$SUBSCRIPTION_FILE" ]; then
    # Try alternative path
    SUBSCRIPTION_FILE="${PROJECT_ROOT}/config-files/subscription-observability-operator.yaml"
    if [ ! -f "$SUBSCRIPTION_FILE" ]; then
        error "Observability Operator subscription file not found. Expected at: ${SCRIPT_DIR}/../config-files/subscription-observability-operator.yaml"
    fi
fi
log "✓ Found subscription file: $SUBSCRIPTION_FILE"

# Ensure openshift-operators namespace exists (it should by default, but check anyway)
if ! oc get ns "$SUBSCRIPTION_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$SUBSCRIPTION_NAMESPACE'..."
    oc create namespace "$SUBSCRIPTION_NAMESPACE"
    log "✓ Namespace '$SUBSCRIPTION_NAMESPACE' created"
else
    log "✓ Namespace '$SUBSCRIPTION_NAMESPACE' already exists"
fi

# Check if subscription already exists
if oc get subscription "$SUBSCRIPTION_NAME" -n "$SUBSCRIPTION_NAMESPACE" &>/dev/null; then
    log "Subscription '$SUBSCRIPTION_NAME' already exists in namespace '$SUBSCRIPTION_NAMESPACE'"
    
    # Get the CSV name from the subscription status
    CSV_NAME=$(oc get subscription "$SUBSCRIPTION_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    
    if [ -n "$CSV_NAME" ]; then
        # Check CSV phase
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        log "Current CSV: $CSV_NAME, Phase: $CSV_PHASE"
        
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "✓ Observability Operator is already installed and succeeded"
            SKIP_OPERATOR_INSTALL=true
        else
            log "Subscription exists but CSV phase is '$CSV_PHASE', waiting for it to succeed..."
            SKIP_OPERATOR_INSTALL=false
        fi
    else
        log "Subscription exists but CSV not yet created, waiting..."
        SKIP_OPERATOR_INSTALL=false
    fi
else
    log "Installing Observability Operator via subscription..."
    SKIP_OPERATOR_INSTALL=false
fi

# Install or wait for operator
if [ "$SKIP_OPERATOR_INSTALL" != "true" ]; then
    # Apply the subscription
    log "Applying Subscription..."
    oc apply -f "$SUBSCRIPTION_FILE"
    
    if [ $? -eq 0 ]; then
        log "✓ Subscription applied successfully"
    else
        error "Failed to apply Subscription"
    fi
    
    # Wait for subscription to create CSV and CSV to be in Succeeded phase
    log "Waiting for Observability Operator to be ready..."
    log "This may take several minutes..."
    
    TIMEOUT=600  # 10 minutes
    ELAPSED=0
    INTERVAL=10
    CSV_NAME=""
    
    # First, wait for CSV to be created
    log "Waiting for ClusterServiceVersion to be created..."
    while [ $ELAPSED -lt $TIMEOUT ] && [ -z "$CSV_NAME" ]; do
        CSV_NAME=$(oc get subscription "$SUBSCRIPTION_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        
        if [ -n "$CSV_NAME" ]; then
            log "✓ ClusterServiceVersion created: $CSV_NAME"
            break
        fi
        
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            log "Waiting for CSV to be created... (${ELAPSED}s/${TIMEOUT}s)"
        fi
        
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    if [ -z "$CSV_NAME" ]; then
        error "ClusterServiceVersion was not created within timeout. Check subscription status: oc get subscription $SUBSCRIPTION_NAME -n $SUBSCRIPTION_NAMESPACE"
    fi
    
    # Now wait for CSV to be in Succeeded phase
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "✓ Observability Operator installed successfully (CSV: $CSV_NAME, phase: $CSV_PHASE)"
            break
        elif [ "$CSV_PHASE" = "Failed" ]; then
            CSV_MESSAGE=$(oc get csv "$CSV_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || echo "Unknown error")
            error "Observability Operator installation failed. CSV: $CSV_NAME, Phase: $CSV_PHASE, Message: $CSV_MESSAGE"
        fi
        
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            log "Waiting for operator installation... (${ELAPSED}s/${TIMEOUT}s, CSV: ${CSV_NAME}, phase: ${CSV_PHASE})"
        fi
        
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$SUBSCRIPTION_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        warning "Observability Operator installation did not complete within timeout. CSV: $CSV_NAME, Current phase: $CSV_PHASE"
        log "You may need to check the operator status manually: oc get csv $CSV_NAME -n $SUBSCRIPTION_NAMESPACE"
    fi
fi

# Verify operator deployments are running
# Note: The operator may deploy to openshift-operators or a different namespace
# Check both openshift-operators and common operator namespaces
log "Verifying operator deployments..."
DEPLOYMENTS=("observability-operator" "obo-prometheus-operator" "perses-operator")
ALL_READY=true

# Check deployments in openshift-operators namespace first
for deployment in "${DEPLOYMENTS[@]}"; do
    if oc get deployment "$deployment" -n "$SUBSCRIPTION_NAMESPACE" &>/dev/null; then
        if oc wait --for=condition=Available deployment/"$deployment" -n "$SUBSCRIPTION_NAMESPACE" --timeout=60s &>/dev/null; then
            log "✓ Deployment '$deployment' is ready in namespace '$SUBSCRIPTION_NAMESPACE'"
        else
            warning "Deployment '$deployment' is not ready yet in namespace '$SUBSCRIPTION_NAMESPACE'"
            ALL_READY=false
        fi
    else
        log "Deployment '$deployment' not found in namespace '$SUBSCRIPTION_NAMESPACE' (may be created later or in different namespace)"
    fi
done

log "========================================================="
log "Step 1 Completed: Cluster Observability Operator installed"
log "========================================================="
log ""

# Step 2: Create Prometheus permission set ConfigMap
log "========================================================="
log "Step 2: Creating Prometheus permission set ConfigMap"
log "========================================================="

CONFIGMAP_NAME="sample-stackrox-prometheus-declarative-configuration"

# Check if ConfigMap already exists
if oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "ConfigMap '$CONFIGMAP_NAME' already exists in namespace '$NAMESPACE'"
    log "Checking if update is needed..."
    
    # Check if the ConfigMap has the expected content
    EXISTING_DATA=$(oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o jsonpath='{.data.prometheus\.yaml}' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_DATA" ] && echo "$EXISTING_DATA" | grep -q "Prometheus Server"; then
        log "✓ ConfigMap already contains Prometheus Server configuration, skipping creation"
    else
        log "ConfigMap exists but may need update, deleting and recreating..."
        oc delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --ignore-not-found=true
        sleep 2
    fi
fi

# Create the ConfigMap
log "Creating ConfigMap '$CONFIGMAP_NAME' in namespace '$NAMESPACE'..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
  namespace: $NAMESPACE
data:
  prometheus.yaml: |
    ---
    name: Prometheus Server
    description: Sample permission set for Prometheus server access
    resources:
    - resource: Administration
      access: READ_ACCESS
    - resource: Alert
      access: READ_ACCESS
    - resource: Cluster
      access: READ_ACCESS
    - resource: Deployment
      access: READ_ACCESS
    - resource: Image
      access: READ_ACCESS
    - resource: Integration
      access: READ_ACCESS
    - resource: Namespace
      access: READ_ACCESS
    - resource: Node
      access: READ_ACCESS
    - resource: WorkflowAdministration
      access: READ_ACCESS
    ---
    name: Prometheus Server
    description: Sample role for Prometheus server access
    accessScope: Unrestricted
    permissionSet: Prometheus Server
EOF

if [ $? -eq 0 ]; then
    log "✓ ConfigMap '$CONFIGMAP_NAME' created successfully"
else
    error "Failed to create ConfigMap '$CONFIGMAP_NAME'"
fi

# Verify ConfigMap was created
if oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "✓ Verified ConfigMap exists in namespace '$NAMESPACE'"
    
    # Display ConfigMap content for verification
    log "ConfigMap content preview:"
    oc get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o jsonpath='{.data.prometheus\.yaml}' | head -n 10
    echo ""
else
    error "ConfigMap verification failed - ConfigMap not found after creation"
fi

log "========================================================="
log "Step 2 Completed: Prometheus permission set ConfigMap created"
log "========================================================="
log ""
log "========================================================="
log "Metrics Dashboard Setup Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - Observability Operator installed via subscription in namespace: $SUBSCRIPTION_NAMESPACE"
log "  - Subscription name: $SUBSCRIPTION_NAME"
log "  - Created ConfigMap: $CONFIGMAP_NAME"
log "  - ConfigMap namespace: $NAMESPACE"
log "  - Contains Prometheus Server permission set and role configuration"
log ""
log "Next steps:"
log "  - Configure Prometheus to scrape RHACS metrics"
log "  - Set up Perses dashboard for visualization"

