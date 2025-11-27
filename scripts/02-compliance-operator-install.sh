#!/bin/bash
# Red Hat Compliance Operator Installation Script
# Installs the Red Hat Compliance Operator using all defaults

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
    echo -e "${GREEN}[COMPLIANCE-OP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-OP]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-OP] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-OP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

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

# Check if Compliance Operator is already installed
log "Checking if Compliance Operator is already installed..."
NAMESPACE="openshift-compliance"

if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    log "Namespace $NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com compliance-operator -n $NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com compliance-operator -n $NAMESPACE -o jsonpath='{.status.currentCSV}')
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$(oc get csv $CURRENT_CSV -n $NAMESPACE -o jsonpath='{.status.phase}')
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Compliance Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                log "Skipping installation..."
                exit 0
            else
                log "Compliance Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "Compliance Operator not found, proceeding with installation..."
fi

# Install Red Hat Compliance Operator
log "Installing Red Hat Compliance Operator..."

# Create namespace for compliance operator
log "Creating openshift-compliance namespace..."
if ! oc create namespace openshift-compliance --dry-run=client -o yaml | oc apply -f -; then
    error "Failed to create openshift-compliance namespace"
fi
log "✓ Namespace created successfully"

# Create OperatorGroup
log "Creating OperatorGroup..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: compliance-operator
  namespace: openshift-compliance
spec:
  targetNamespaces:
  - openshift-compliance
EOF
then
    error "Failed to create OperatorGroup"
fi
log "✓ OperatorGroup created successfully"

# Create Subscription for Red Hat Compliance Operator
log "Creating Subscription for Red Hat Compliance Operator..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: compliance-operator
  namespace: openshift-compliance
spec:
  channel: stable
  installPlanApproval: Automatic
  name: compliance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: compliance-operator.v1.7.1
EOF
then
    error "Failed to create Subscription"
fi
log "✓ Subscription created successfully"

# Wait for the operator to be installed
log "Waiting for Compliance Operator to be installed..."
log "This may take a few minutes..."

# Wait for CSV to be created and installed
log "Waiting for ClusterServiceVersion to be created..."
MAX_WAIT=60
WAIT_COUNT=0
while ! oc get csv -n openshift-compliance 2>/dev/null | grep -q compliance-operator; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        error "CSV not created after $((MAX_WAIT * 10)) seconds. Check subscription status: oc get subscription compliance-operator -n openshift-compliance"
    fi
    log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Get the CSV name (get the first one, or the one that's installed)
CSV_NAME=$(oc get csv -n openshift-compliance -o name 2>/dev/null | grep compliance-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    # Fallback: try getting CSV by label
    CSV_NAME=$(oc get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for compliance-operator"
fi
log "Found CSV: $CSV_NAME"

# Wait for CSV to be in Succeeded phase
log "Waiting for ClusterServiceVersion to be installed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n openshift-compliance --timeout=300s; then
    CSV_STATUS=$(oc get csv "$CSV_NAME" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    error "CSV failed to reach Succeeded phase. Current status: $CSV_STATUS. Check CSV details: oc describe csv $CSV_NAME -n openshift-compliance"
fi
log "✓ CSV is in Succeeded phase"

# Wait for the operator deployment to be ready
log "Waiting for Compliance Operator deployment to be ready..."
if ! oc wait --for=condition=Available deployment/compliance-operator -n openshift-compliance --timeout=300s; then
    error "Compliance Operator deployment failed to become Available. Check deployment: oc get deployment compliance-operator -n openshift-compliance"
fi
log "✓ Compliance Operator deployment is ready"

# Verify installation
log "Verifying Compliance Operator installation..."

# Check if the operator is running
if ! oc get deployment compliance-operator -n openshift-compliance >/dev/null 2>&1; then
    error "Compliance Operator deployment not found. Check namespace: oc get deployment -n openshift-compliance"
fi
log "✓ Compliance Operator deployment found"

# Check operator pods
log "Checking operator pods..."
POD_STATUS=$(oc get pods -n openshift-compliance -l name=compliance-operator -o jsonpath='{.items[*].status.phase}' || echo "")
if [ -z "$POD_STATUS" ]; then
    error "No Compliance Operator pods found. Check pods: oc get pods -n openshift-compliance"
fi
oc get pods -n openshift-compliance -l name=compliance-operator

# Verify pods are running
if echo "$POD_STATUS" | grep -qv "Running"; then
    error "Compliance Operator pods are not all Running. Current status: $POD_STATUS"
fi
log "✓ All Compliance Operator pods are Running"

# Check CSV (ClusterServiceVersion)
log "Checking ClusterServiceVersion..."
if ! oc get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance >/dev/null 2>&1; then
    error "Compliance Operator CSV not found. Check CSV: oc get csv -n openshift-compliance"
fi
oc get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance

# Display operator status
log "Compliance Operator installation completed successfully!"
log "========================================================="
log "Namespace: openshift-compliance"
log "Operator: compliance-operator"
log "CSV: $CSV_NAME"
log "========================================================="
