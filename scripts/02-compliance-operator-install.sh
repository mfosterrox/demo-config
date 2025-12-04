#!/bin/bash
# Red Hat Compliance Operator Installation Script
# Installs the Red Hat Compliance Operator using all defaults
# This script also initializes all environment variables needed by other scripts

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

# Function to save variable to ~/.bashrc
save_to_bashrc() {
    local var_name="$1"
    local var_value="$2"
    
    # Remove existing export line for this variable
    if [ -f ~/.bashrc ]; then
        sed -i "/^export ${var_name}=/d" ~/.bashrc
    fi
    
    # Append export statement to ~/.bashrc
    echo "export ${var_name}=\"${var_value}\"" >> ~/.bashrc
    export "${var_name}=${var_value}"
}

# Function to load variable from ~/.bashrc if it exists
load_from_bashrc() {
    local var_name="$1"
    
    # First check if variable is already set in environment
    local env_value=$(eval "echo \${${var_name}:-}")
    if [ -n "$env_value" ]; then
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

# Initialize environment variables
log "========================================================="
log "Initializing environment variables"
log "========================================================="

# Ensure ~/.bashrc exists
if [ ! -f ~/.bashrc ]; then
    log "Creating ~/.bashrc file..."
    touch ~/.bashrc
fi

# Clean up any malformed source commands in bashrc
if grep -q "^source $" ~/.bashrc; then
    log "Cleaning up malformed source commands in ~/.bashrc..."
    sed -i '/^source $/d' ~/.bashrc
fi

# Set up SCRIPT_DIR and PROJECT_ROOT (always set these based on current script location)
log "Setting up SCRIPT_DIR and PROJECT_ROOT..."
save_to_bashrc "SCRIPT_DIR" "$SCRIPT_DIR"
save_to_bashrc "PROJECT_ROOT" "$PROJECT_ROOT"
log "✓ SCRIPT_DIR=$SCRIPT_DIR"
log "✓ PROJECT_ROOT=$PROJECT_ROOT"

# Set up NAMESPACE (default to tssc-acs for RHACS, but can be overridden)
if [ -z "${NAMESPACE:-}" ]; then
    EXISTING_NAMESPACE=$(load_from_bashrc "NAMESPACE")
    if [ -n "$EXISTING_NAMESPACE" ]; then
        NAMESPACE="$EXISTING_NAMESPACE"
        log "✓ Loaded NAMESPACE from ~/.bashrc: $NAMESPACE"
    else
        NAMESPACE="tssc-acs"
        save_to_bashrc "NAMESPACE" "$NAMESPACE"
        log "✓ Set NAMESPACE default: $NAMESPACE"
    fi
else
    save_to_bashrc "NAMESPACE" "$NAMESPACE"
    log "✓ NAMESPACE already set: $NAMESPACE"
fi

# Load existing variables from ~/.bashrc if they exist (set by script 01 which runs first)
log "Loading existing variables from ~/.bashrc..."

# Load ROX_ENDPOINT if it exists (set by script 01)
EXISTING_ROX_ENDPOINT=$(load_from_bashrc "ROX_ENDPOINT")
if [ -n "$EXISTING_ROX_ENDPOINT" ]; then
    log "✓ Loaded ROX_ENDPOINT from ~/.bashrc"
else
    log "  ROX_ENDPOINT not found (should be set by script 01-rhacs-setup.sh)"
fi

# Load ROX_API_TOKEN if it exists (set by script 01)
EXISTING_ROX_API_TOKEN=$(load_from_bashrc "ROX_API_TOKEN")
if [ -n "$EXISTING_ROX_API_TOKEN" ]; then
    log "✓ Loaded ROX_API_TOKEN from ~/.bashrc"
else
    log "  ROX_API_TOKEN not found (should be set by script 01-rhacs-setup.sh)"
fi

# Load TUTORIAL_HOME if it exists (set by script 03)
EXISTING_TUTORIAL_HOME=$(load_from_bashrc "TUTORIAL_HOME")
if [ -n "$EXISTING_TUTORIAL_HOME" ]; then
    log "✓ Loaded TUTORIAL_HOME from ~/.bashrc"
else
    log "  TUTORIAL_HOME not found (will be set by script 07-deploy-applications.sh)"
fi

# Load ADMIN_PASSWORD if it exists (set by script 01)
EXISTING_ADMIN_PASSWORD=$(load_from_bashrc "ADMIN_PASSWORD")
if [ -n "$EXISTING_ADMIN_PASSWORD" ]; then
    log "✓ Loaded ADMIN_PASSWORD from ~/.bashrc"
else
    log "  ADMIN_PASSWORD not found (should be set by script 01-rhacs-setup.sh)"
fi

log "========================================================="
log "Environment variables initialized"
log "========================================================="
log ""

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

# Restart RHACS sensor to ensure it picks up Compliance Operator results
# This is important because RHACS is installed before Compliance Operator,
# so the sensor needs to restart to sync any existing compliance results
log ""
log "Restarting RHACS sensor to sync Compliance Operator results..."
RHACS_NAMESPACE=$(load_from_bashrc "NAMESPACE")
if [ -z "$RHACS_NAMESPACE" ]; then
    RHACS_NAMESPACE="tssc-acs"
fi

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    # Check if sensor exists (RHACS should be installed by now)
    if oc get deployment sensor -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
        log "Found RHACS sensor deployment, restarting sensor pods..."
        if oc delete pods -l app.kubernetes.io/component=sensor -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
            log "✓ Sensor pods deleted, waiting for restart..."
            # Wait for sensor to be ready (with timeout)
            if oc wait --for=condition=Available deployment/sensor -n "$RHACS_NAMESPACE" --timeout=120s &>/dev/null 2>&1; then
                log "✓ Sensor pods restarted successfully"
            else
                warning "Sensor pods restarted but may not be fully ready yet"
            fi
        else
            warning "Could not restart sensor pods (may not exist yet or already restarting)"
        fi
    else
        log "RHACS sensor not found in namespace $RHACS_NAMESPACE, skipping sensor restart"
        log "Note: Sensor will automatically sync compliance results when it starts"
    fi
else
    log "OpenShift CLI (oc) not available, skipping sensor restart"
    log "Note: You may need to manually restart the sensor: oc delete pods -l app.kubernetes.io/component=sensor -n $RHACS_NAMESPACE"
fi
log ""

