#!/bin/bash
# Red Hat Compliance Operator Installation Script
# Installs the Red Hat Compliance Operator using all defaults

set -e

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
    echo -e "${RED}[COMPLIANCE-OP]${NC} $1"
    exit 1
}

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Check if we have cluster admin privileges
if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to install operators"
fi

log "Prerequisites validated successfully"

# Install Red Hat Compliance Operator
log "Installing Red Hat Compliance Operator..."

# Create namespace for compliance operator
log "Creating openshift-compliance namespace..."
oc create namespace openshift-compliance --dry-run=client -o yaml | oc apply -f -

# Create OperatorGroup
log "Creating OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: compliance-operator
  namespace: openshift-compliance
spec:
  targetNamespaces:
  - openshift-compliance
EOF

# Create Subscription for Red Hat Compliance Operator
log "Creating Subscription for Red Hat Compliance Operator..."
cat <<EOF | oc apply -f -
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

# Wait for the operator to be installed
log "Waiting for Compliance Operator to be installed..."
log "This may take a few minutes..."

# Wait for CSV to be created and installed
log "Waiting for ClusterServiceVersion to be created..."
while ! oc get csv -n openshift-compliance | grep compliance-operator &>/dev/null; do
    log "Waiting for CSV to be created..."
    sleep 10
done

# Get the CSV name
CSV_NAME=$(oc get csv -n openshift-compliance | grep compliance-operator | awk '{print $1}')
log "Found CSV: $CSV_NAME"

# Wait for CSV to be in Succeeded phase
log "Waiting for ClusterServiceVersion to be installed..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/$CSV_NAME -n openshift-compliance --timeout=300s

# Wait for the operator deployment to be ready
log "Waiting for Compliance Operator deployment to be ready..."
oc wait --for=condition=Available deployment/compliance-operator -n openshift-compliance --timeout=300s

# Verify installation
log "Verifying Compliance Operator installation..."

# Check if the operator is running
if oc get deployment compliance-operator -n openshift-compliance &>/dev/null; then
    log "✓ Compliance Operator deployment found"
else
    error "Compliance Operator deployment not found"
fi

# Check operator pods
log "Checking operator pods..."
oc get pods -n openshift-compliance -l name=compliance-operator

# Check CSV (ClusterServiceVersion)
log "Checking ClusterServiceVersion..."
oc get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance

# Display operator status
log "Compliance Operator installation completed successfully!"
log "========================================================="
log "Namespace: openshift-compliance"
log "Operator: compliance-operator"
log "========================================================="
