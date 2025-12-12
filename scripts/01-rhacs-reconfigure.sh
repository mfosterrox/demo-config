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

# Step 1: Find and delete RHACS subscriptions across all namespaces
log "========================================================="
log "Step 1: Deleting RHACS Subscriptions"
log "========================================================="
log ""

# Search for RHACS subscriptions in all namespaces
RHACS_SUBSCRIPTIONS=$(oc get subscriptions.operators.coreos.com --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    namespace = item.get('metadata', {}).get('namespace', '')
    package = item.get('spec', {}).get('name', '')
    if 'rhacs' in name.lower() or 'rhacs' in package.lower() or 'stackrox' in name.lower() or 'stackrox' in package.lower():
        print(f'{namespace}/{name}')
" 2>/dev/null || echo "")

if [ -n "$RHACS_SUBSCRIPTIONS" ]; then
    log "Found RHACS subscriptions:"
    echo "$RHACS_SUBSCRIPTIONS" | while IFS='/' read -r namespace name; do
        log "  - $namespace/$name"
    done
    log ""
    
    echo "$RHACS_SUBSCRIPTIONS" | while IFS='/' read -r namespace name; do
        delete_resource "subscription.operators.coreos.com" "$name" "$namespace" "Subscription $name"
    done
else
    log "No RHACS subscriptions found"
fi

log ""

# Step 2: Find and delete RHACS CSV resources across all namespaces
log "========================================================="
log "Step 2: Deleting RHACS ClusterServiceVersions"
log "========================================================="
log ""

# Search for RHACS CSV resources in all namespaces
RHACS_CSVS=$(oc get csv --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    namespace = item.get('metadata', {}).get('namespace', '')
    display_name = item.get('spec', {}).get('displayName', '')
    if 'rhacs' in name.lower() or 'rhacs' in display_name.lower() or 'stackrox' in name.lower() or 'stackrox' in display_name.lower():
        print(f'{namespace}/{name}')
" 2>/dev/null || echo "")

if [ -n "$RHACS_CSVS" ]; then
    log "Found RHACS CSV resources:"
    echo "$RHACS_CSVS" | while IFS='/' read -r namespace name; do
        log "  - $namespace/$name"
    done
    log ""
    
    echo "$RHACS_CSVS" | while IFS='/' read -r namespace name; do
        delete_resource "csv" "$name" "$namespace" "CSV $name"
    done
else
    log "No RHACS CSV resources found"
fi

log ""

# Step 3: Find and delete RHACS OperatorGroups
log "========================================================="
log "Step 3: Deleting RHACS OperatorGroups"
log "========================================================="
log ""

# Search for RHACS OperatorGroups in all namespaces
RHACS_OPERATORGROUPS=$(oc get operatorgroups.operators.coreos.com --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    namespace = item.get('metadata', {}).get('namespace', '')
    if 'rhacs' in name.lower() or 'stackrox' in name.lower():
        print(f'{namespace}/{name}')
" 2>/dev/null || echo "")

if [ -n "$RHACS_OPERATORGROUPS" ]; then
    log "Found RHACS OperatorGroups:"
    echo "$RHACS_OPERATORGROUPS" | while IFS='/' read -r namespace name; do
        log "  - $namespace/$name"
    done
    log ""
    
    echo "$RHACS_OPERATORGROUPS" | while IFS='/' read -r namespace name; do
        delete_resource "operatorgroup.operators.coreos.com" "$name" "$namespace" "OperatorGroup $name"
    done
else
    log "No RHACS OperatorGroups found"
fi

log ""

# Step 4: Check for and delete InstallPlans related to RHACS
log "========================================================="
log "Step 4: Deleting RHACS InstallPlans"
log "========================================================="
log ""

# Search for RHACS InstallPlans in all namespaces
RHACS_INSTALLPLANS=$(oc get installplans.operators.coreos.com --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    namespace = item.get('metadata', {}).get('namespace', '')
    csv_name = item.get('spec', {}).get('clusterServiceVersionNames', [])
    csv_str = ' '.join(csv_name).lower()
    if 'rhacs' in name.lower() or 'rhacs' in csv_str or 'stackrox' in name.lower() or 'stackrox' in csv_str:
        print(f'{namespace}/{name}')
" 2>/dev/null || echo "")

if [ -n "$RHACS_INSTALLPLANS" ]; then
    log "Found RHACS InstallPlans:"
    echo "$RHACS_INSTALLPLANS" | while IFS='/' read -r namespace name; do
        log "  - $namespace/$name"
    done
    log ""
    
    echo "$RHACS_INSTALLPLANS" | while IFS='/' read -r namespace name; do
        delete_resource "installplan.operators.coreos.com" "$name" "$namespace" "InstallPlan $name"
    done
else
    log "No RHACS InstallPlans found"
fi

log ""

# Step 5: Wait for resources to be fully deleted
log "========================================================="
log "Step 5: Waiting for resources to be fully deleted"
log "========================================================="
log ""

log "Waiting for finalizers to complete and resources to be fully removed..."
sleep 10

# Verify deletions
log "Verifying deletions..."

VERIFICATION_FAILED=false

# Check subscriptions
REMAINING_SUBS=$(oc get subscriptions.operators.coreos.com --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    package = item.get('spec', {}).get('name', '')
    if 'rhacs' in name.lower() or 'rhacs' in package.lower() or 'stackrox' in name.lower() or 'stackrox' in package.lower():
        print(f'{item.get(\"metadata\", {}).get(\"namespace\", \"\")}/{name}')
" 2>/dev/null || echo "")

if [ -n "$REMAINING_SUBS" ]; then
    warning "Some subscriptions still exist:"
    echo "$REMAINING_SUBS" | while IFS='/' read -r namespace name; do
        warning "  - $namespace/$name"
    done
    VERIFICATION_FAILED=true
fi

# Check CSVs
REMAINING_CSVS=$(oc get csv --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item.get('metadata', {}).get('name', '')
    display_name = item.get('spec', {}).get('displayName', '')
    if 'rhacs' in name.lower() or 'rhacs' in display_name.lower() or 'stackrox' in name.lower() or 'stackrox' in display_name.lower():
        print(f'{item.get(\"metadata\", {}).get(\"namespace\", \"\")}/{name}')
" 2>/dev/null || echo "")

if [ -n "$REMAINING_CSVS" ]; then
    warning "Some CSV resources still exist (may be in terminating state):"
    echo "$REMAINING_CSVS" | while IFS='/' read -r namespace name; do
        warning "  - $namespace/$name"
    done
    VERIFICATION_FAILED=true
fi

if [ "$VERIFICATION_FAILED" = true ]; then
    warning "Some resources may still be terminating. This is normal if they have finalizers."
    warning "You can check status with: oc get subscriptions,csv,operatorgroups --all-namespaces | grep -i rhacs"
else
    log "✓ All RHACS operator resources have been deleted"
fi

log ""
log "========================================================="
log "✓ RHACS Operator cleanup completed!"
log "========================================================="
log ""
log "Summary:"
log "  - RHACS Subscriptions: Deleted"
log "  - RHACS ClusterServiceVersions: Deleted"
log "  - RHACS OperatorGroups: Deleted"
log "  - RHACS InstallPlans: Deleted"
log ""
log "Note: If any resources are still showing, they may be in"
log "      'Terminating' state due to finalizers. This is normal"
log "      and they will be removed automatically."
log ""

