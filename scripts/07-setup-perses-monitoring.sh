#!/bin/bash
# Perses Monitoring Setup Script
# Installs Cluster Observability Operator and configures Perses monitoring

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[PERSES-MONITORING]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[PERSES-MONITORING]${NC} $1"
}

error() {
    echo -e "${RED}[PERSES-MONITORING] ERROR:${NC} $1" >&2
    echo -e "${RED}[PERSES-MONITORING] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"

# Step 1: Install Cluster Observability Operator
log ""
log "========================================================="
log "Step 1: Installing Cluster Observability Operator"
log "========================================================="

OPERATOR_NAMESPACE="openshift-cluster-observability-operator"

# Check if Cluster Observability Operator is already installed
log "Checking if Cluster Observability Operator is already installed..."

if oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "Namespace $OPERATOR_NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$(oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}')
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Cluster Observability Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                log "Skipping installation..."
            else
                log "Cluster Observability Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "Cluster Observability Operator not found, proceeding with installation..."
fi

# Create namespace for Cluster Observability Operator
log "Creating $OPERATOR_NAMESPACE namespace..."
if ! oc create namespace $OPERATOR_NAMESPACE --dry-run=client -o yaml | oc apply -f -; then
    error "Failed to create $OPERATOR_NAMESPACE namespace"
fi
log "✓ Namespace created successfully"

# Create OperatorGroup (if it doesn't exist)
log "Checking for OperatorGroup..."
if ! oc get operatorgroup -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "Creating OperatorGroup..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
EOF
    then
        error "Failed to create OperatorGroup"
    fi
    log "✓ OperatorGroup created successfully"
else
    log "✓ OperatorGroup already exists"
fi

# Create Subscription for Cluster Observability Operator
log "Creating Subscription for Cluster Observability Operator..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: cluster-observability-operator.v1.3.0
EOF
then
    error "Failed to create Subscription"
fi
log "✓ Subscription created successfully"

# Wait for the operator to be installed
log "Waiting for Cluster Observability Operator to be installed..."
log "This may take a few minutes..."

# Wait for CSV to be created and installed
log "Waiting for ClusterServiceVersion to be created..."
MAX_WAIT=60
WAIT_COUNT=0
while ! oc get csv -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q cluster-observability-operator; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        error "CSV not created after $((MAX_WAIT * 10)) seconds. Check subscription status: oc get subscription cluster-observability-operator -n $OPERATOR_NAMESPACE"
    fi
    log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Get the CSV name
CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -o name 2>/dev/null | grep cluster-observability-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    # Fallback: try getting CSV by label
    CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for cluster-observability-operator"
fi
log "Found CSV: $CSV_NAME"

# Wait for CSV to be in Succeeded phase
log "Waiting for ClusterServiceVersion to be installed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $OPERATOR_NAMESPACE --timeout=300s; then
    CSV_STATUS=$(oc get csv "$CSV_NAME" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    error "CSV failed to reach Succeeded phase. Current status: $CSV_STATUS. Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
fi
log "✓ CSV is in Succeeded phase"

# Wait for the operator deployment to be ready
log "Waiting for Cluster Observability Operator deployment to be ready..."
if ! oc wait --for=condition=Available deployment/cluster-observability-operator -n $OPERATOR_NAMESPACE --timeout=300s; then
    error "Cluster Observability Operator deployment failed to become Available. Check deployment: oc get deployment cluster-observability-operator -n $OPERATOR_NAMESPACE"
fi
log "✓ Cluster Observability Operator deployment is ready"

# Verify installation
log "Verifying Cluster Observability Operator installation..."

# Check if the operator is running
if ! oc get deployment cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    error "Cluster Observability Operator deployment not found. Check namespace: oc get deployment -n $OPERATOR_NAMESPACE"
fi
log "✓ Cluster Observability Operator deployment found"

# Check operator pods
log "Checking operator pods..."
POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
if [ -z "$POD_STATUS" ]; then
    # Try alternative label selector
    POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
fi
if [ -n "$POD_STATUS" ]; then
    oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator 2>/dev/null || oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator
else
    warning "No Cluster Observability Operator pods found with standard labels. Checking all pods in namespace..."
    oc get pods -n $OPERATOR_NAMESPACE
fi

# Verify pods are running
if [ -n "$POD_STATUS" ] && echo "$POD_STATUS" | grep -qv "Running"; then
    warning "Some Cluster Observability Operator pods are not Running. Current status: $POD_STATUS"
else
    log "✓ All Cluster Observability Operator pods are Running"
fi

# Check CSV (ClusterServiceVersion)
log "Checking ClusterServiceVersion..."
if ! oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator >/dev/null 2>&1; then
    warning "Cluster Observability Operator CSV not found with expected label. Checking all CSVs..."
    oc get csv -n $OPERATOR_NAMESPACE
else
    oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator
fi

# Display operator status
log ""
log "Cluster Observability Operator installation completed successfully!"
log "========================================================="
log "Namespace: $OPERATOR_NAMESPACE"
log "Operator: cluster-observability-operator"
log "CSV: $CSV_NAME"
log "========================================================="
log ""

