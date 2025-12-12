#!/bin/bash
# RHACS Central Installation Script
# Installs RHACS operator subscription in rhacs-operator namespace

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
    echo -e "${GREEN}[RHACS-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"

# RHACS operator namespace
OPERATOR_NAMESPACE="rhacs-operator"

# Ensure namespace exists
log "Ensuring namespace '$OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
    log "Creating namespace '$OPERATOR_NAMESPACE'..."
    oc create namespace "$OPERATOR_NAMESPACE" || error "Failed to create namespace"
fi
log "✓ Namespace '$OPERATOR_NAMESPACE' exists"

# Check if RHACS operator is already installed
log ""
log "Checking RHACS operator status"

OPERATOR_PACKAGE="rhacs-operator"
if oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    CURRENT_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        if oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ RHACS operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                CSV_NAME="$CURRENT_CSV"
                NEEDS_INSTALL=false
            else
                log "RHACS operator subscription exists but CSV is in phase: $CSV_PHASE"
                NEEDS_INSTALL=true
            fi
        else
            log "RHACS operator subscription exists but CSV not found"
            NEEDS_INSTALL=true
        fi
    else
        log "RHACS operator subscription exists but CSV not yet determined"
        NEEDS_INSTALL=true
    fi
else
    log "RHACS operator not found, proceeding with installation..."
    NEEDS_INSTALL=true
fi

if [ "${NEEDS_INSTALL:-true}" = true ]; then
    # Determine channel
    log ""
    log "Determining available channel for RHACS operator..."
    
    CHANNEL=""
    if oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace >/dev/null 2>&1; then
        AVAILABLE_CHANNELS=$(oc get packagemanifest "$OPERATOR_PACKAGE" -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        
        if [ -n "$AVAILABLE_CHANNELS" ]; then
            log "Available channels: $AVAILABLE_CHANNELS"
            
            # RHACS typically uses "stable" channel
            PREFERRED_CHANNELS=("stable")
            
            for pref_channel in "${PREFERRED_CHANNELS[@]}"; do
                if echo "$AVAILABLE_CHANNELS" | grep -q "\b$pref_channel\b"; then
                    CHANNEL="$pref_channel"
                    log "✓ Selected channel: $CHANNEL"
                    break
                fi
            done
            
            # If no preferred channel found, use the first available channel
            if [ -z "$CHANNEL" ]; then
                CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
                log "✓ Using first available channel: $CHANNEL"
            fi
        else
            warning "Could not determine available channels from packagemanifest"
        fi
    else
        warning "Package manifest not found in catalog (may still be syncing)"
    fi
    
    # Fallback to default channel if we couldn't determine it
    if [ -z "$CHANNEL" ]; then
        CHANNEL="stable"
        log "Using default channel: $CHANNEL"
    fi
    
    # Create OperatorGroup if it doesn't exist
    log ""
    log "Ensuring OperatorGroup exists..."
    if ! oc get operatorgroup -n "$OPERATOR_NAMESPACE" &>/dev/null 2>&1; then
        log "Creating OperatorGroup..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
EOF
        log "✓ OperatorGroup created"
    else
        log "✓ OperatorGroup already exists"
    fi
    
    # Create or update Subscription
    log ""
    log "Creating/updating Subscription..."
    log "  Channel: $CHANNEL"
    log "  Source: redhat-operators"
    log "  SourceNamespace: openshift-marketplace"
    
    if oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
        
        if [ "$EXISTING_CHANNEL" != "$CHANNEL" ]; then
            log "  Updating subscription channel from '$EXISTING_CHANNEL' to '$CHANNEL'..."
            oc patch subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || error "Failed to update subscription channel"
            log "✓ Subscription channel updated to $CHANNEL"
            sleep 3
        else
            log "✓ Subscription already exists with channel: $CHANNEL"
        fi
    else
        log "  Creating new subscription..."
        if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $OPERATOR_PACKAGE
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: $OPERATOR_PACKAGE
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
        then
            error "Failed to create Subscription"
        fi
        log "✓ Subscription created successfully"
        sleep 3
    fi
    
    # Wait for CSV to be created
    log ""
    log "Waiting for ClusterServiceVersion to be created..."
    MAX_WAIT=90
    WAIT_COUNT=0
    CSV_CREATED=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -q "$OPERATOR_PACKAGE"; then
            CSV_CREATED=true
            log "✓ CSV created"
            break
        fi
        
        # Show progress every 10 seconds
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
            oc get csv,subscription,installplan -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -i "$OPERATOR_PACKAGE" | head -5 || true
            log ""
        fi
        
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    if [ "$CSV_CREATED" = false ]; then
        warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
        oc get subscription,installplan -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -i "$OPERATOR_PACKAGE" || true
        error "CSV not created. Check subscription status: oc get subscription $OPERATOR_PACKAGE -n $OPERATOR_NAMESPACE"
    fi
    
    # Get the CSV name
    CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep "$OPERATOR_PACKAGE" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -l operators.coreos.com/$OPERATOR_PACKAGE.$OPERATOR_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        error "Failed to find CSV name for $OPERATOR_PACKAGE"
    fi
    log "Found CSV: $CSV_NAME"
    
    # Wait for CSV to be in Succeeded phase
    log ""
    log "Waiting for ClusterServiceVersion to be installed..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n "$OPERATOR_NAMESPACE" --timeout=300s 2>/dev/null; then
        CSV_STATUS=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
        log "Checking CSV details..."
        oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE"
        log "Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
    else
        log "✓ CSV is in Succeeded phase"
    fi
fi

log ""
log "========================================================="
log "RHACS Operator Installation Completed!"
log "========================================================="
log "Operator Namespace: $OPERATOR_NAMESPACE"
log "Operator: $OPERATOR_PACKAGE"
if [ -n "${CSV_NAME:-}" ] && [ "$CSV_NAME" != "null" ]; then
    log "CSV: $CSV_NAME"
fi
if [ -n "${CHANNEL:-}" ] && [ "$CHANNEL" != "null" ]; then
    log "Channel: ${CHANNEL}"
fi
log "========================================================="
log ""
log "RHACS operator is installed and ready."
log "Next step: Create Central resource to deploy RHACS Central."
log ""

