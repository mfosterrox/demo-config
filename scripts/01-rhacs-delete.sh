#!/bin/bash
# RHACS Operator Cleanup Script
# Deletes all RHACS-related operators from the OpenShift cluster
# This script is idempotent and safe to run multiple times

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[RHACS-RECONFIGURE]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-RECONFIGURE]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-RECONFIGURE] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-RECONFIGURE] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "RHACS Operator Cleanup Script"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i delete subscriptions --all-namespaces &>/dev/null; then
    error "Cluster admin privileges required to delete operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log ""

# Function to delete resources if they exist
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local description="${4:-$resource_type/$resource_name}"
    
    if oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
        log "Deleting $description in namespace $namespace..."
        if oc delete "$resource_type" "$resource_name" -n "$namespace" --timeout=60s &>/dev/null; then
            log "✓ Deleted $description"
            return 0
        else
            warning "Failed to delete $description (may already be deleting)"
            return 1
        fi
    else
        log "  $description not found in namespace $namespace (skipping)"
        return 0
    fi
}

# Function to delete all resources of a type in a namespace
delete_all_resources() {
    local resource_type=$1
    local namespace=$2
    local label_selector="${3:-}"
    
    local resources
    if [ -n "$label_selector" ]; then
        resources=$(oc get "$resource_type" -n "$namespace" -l "$label_selector" -o name 2>/dev/null || echo "")
    else
        resources=$(oc get "$resource_type" -n "$namespace" -o name 2>/dev/null || echo "")
    fi
    
    if [ -n "$resources" ]; then
        log "Found $(echo "$resources" | wc -l | tr -d '[:space:]') $resource_type resource(s) in namespace $namespace"
        for resource in $resources; do
            resource_name=$(echo "$resource" | cut -d'/' -f2)
            delete_resource "$resource_type" "$resource_name" "$namespace" "$resource"
        done
    else
        log "  No $resource_type resources found in namespace $namespace"
    fi
}

# Step 1: Find namespaces with RHACS/ACS operator subscriptions (excluding rhacs-operator)
log "========================================================="
log "Step 1: Finding namespaces with RHACS/ACS operator subscriptions"
log "========================================================="
log ""

CORRECT_NAMESPACE="rhacs-operator"

# Find all namespaces that contain RHACS/ACS operator subscriptions
RHACS_NAMESPACES=$(oc get subscriptions.operators.coreos.com --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
rhacs_namespaces = set()
for item in data.get('items', []):
    namespace = item.get('metadata', {}).get('namespace', '')
    package = item.get('spec', {}).get('name', '')
    # Look for rhacs-operator or acs-operator subscriptions
    if package in ['rhacs-operator', 'acs-operator'] and namespace:
        rhacs_namespaces.add(namespace)

# Exclude the correct namespace
for ns in sorted(rhacs_namespaces):
    if ns.lower() != 'rhacs-operator':
        print(ns)
" 2>/dev/null)

# Handle empty result
if [ -z "$RHACS_NAMESPACES" ]; then
    RHACS_NAMESPACES=""
fi

if [ -n "$RHACS_NAMESPACES" ]; then
    log "Found namespaces with RHACS operator resources (excluding $CORRECT_NAMESPACE):"
    echo "$RHACS_NAMESPACES" | while read -r namespace; do
        if [ -n "$namespace" ]; then
            log "  - $namespace"
        fi
    done
    log ""
    
    # Step 2: Delete the incorrect namespaces
    log "========================================================="
    log "Step 2: Deleting namespaces with RHACS operator resources"
    log "========================================================="
    log ""
    
    log "Note: '$CORRECT_NAMESPACE' is the correct namespace and will NOT be deleted"
    log ""
    
    echo "$RHACS_NAMESPACES" | while read -r namespace; do
        if [ -n "$namespace" ] && [ "$namespace" != "$CORRECT_NAMESPACE" ]; then
            log "Deleting namespace: $namespace"
            if oc delete namespace "$namespace" --timeout=120s &>/dev/null; then
                log "✓ Namespace $namespace deletion initiated"
            else
                warning "Failed to delete namespace $namespace (may already be deleting)"
            fi
        fi
    done
    
    log ""
    log "Waiting for namespace deletion(s) to complete..."
    sleep 15
    
    # Step 3: Verify deletion
    log "========================================================="
    log "Step 3: Verifying namespace deletion"
    log "========================================================="
    log ""
    
    echo "$RHACS_NAMESPACES" | while read -r namespace; do
        if [ -n "$namespace" ] && [ "$namespace" != "$CORRECT_NAMESPACE" ]; then
            if oc get namespace "$namespace" &>/dev/null 2>&1; then
                NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                if [ "$NS_PHASE" = "Terminating" ]; then
                    log "  Namespace $namespace is still terminating (this is normal - deletion in progress)"
                else
                    warning "  Namespace $namespace still exists (phase: $NS_PHASE)"
                fi
            else
                log "✓ Namespace $namespace has been deleted"
            fi
        fi
    done
else
    log "No namespaces with RHACS operator resources found (excluding $CORRECT_NAMESPACE)"
    log "  (No cleanup needed)"
fi

log ""
log "========================================================="
log "✓ RHACS Operator cleanup completed!"
log "========================================================="
log ""
log "Summary:"
log "  - Namespaces with RHACS operator resources (excluding $CORRECT_NAMESPACE) deleted"
log ""
log "Note: Namespace deletion may take a few minutes to complete"
log "      if there are finalizers. Resources will be removed"
log "      automatically once the namespace is fully deleted."
log ""

