#!/bin/bash
# Complete Cleanup Script
# Deletes all resources created by the installation scripts:
# - RHACS operator and resources
# - Cluster Observability Operator and monitoring resources
# - Compliance Operator and resources
# - Cert-Manager operator (if installed by our scripts)
#
# This script deletes everything at once and then verifies cleanup

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
    echo -e "${GREEN}[CLEANUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[CLEANUP]${NC} $1"
}

error() {
    echo -e "${RED}[CLEANUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[CLEANUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Complete Cleanup Script"
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
log "========================================================="
log "Step 1: Deleting all custom resources"
log "========================================================="
log ""

# Function to delete resources if they exist (non-fatal)
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local description="${4:-$resource_type/$resource_name}"
    
    if oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null 2>&1; then
        log "  Deleting $description in namespace $namespace..."
        if oc delete "$resource_type" "$resource_name" -n "$namespace" --timeout=60s &>/dev/null 2>&1; then
            log "    ✓ Deleted $description"
            return 0
        else
            warning "    Failed to delete $description (may already be deleting)"
            return 1
        fi
    else
        return 0
    fi
}

# Function to delete all resources of a type in a namespace
delete_all_resources() {
    local resource_type=$1
    local namespace=$2
    local description="${3:-$resource_type resources}"
    
    local resources=$(oc get "$resource_type" -n "$namespace" -o name 2>/dev/null || echo "")
    
    if [ -n "$resources" ]; then
        log "  Found $(echo "$resources" | wc -l | tr -d '[:space:]') $description in namespace $namespace"
        for resource in $resources; do
            resource_name=$(echo "$resource" | cut -d'/' -f2- | cut -d'.' -f1)
            delete_resource "$resource_type" "$resource_name" "$namespace" "$resource"
        done
    fi
}

# Function to delete compliance scans with finalizer removal
delete_compliance_scans() {
    local namespace=$1
    
    local scans=$(oc get compliancescan.compliance.openshift.io -n "$namespace" -o name 2>/dev/null || echo "")
    
    if [ -n "$scans" ]; then
        log "  Found $(echo "$scans" | wc -l | tr -d '[:space:]') ComplianceScan resources in namespace $namespace"
        for scan in $scans; do
            scan_name=$(echo "$scan" | cut -d'/' -f2)
            
            if oc get compliancescan.compliance.openshift.io "$scan_name" -n "$namespace" &>/dev/null 2>&1; then
                log "  Processing ComplianceScan: $scan_name"
                
                # Remove finalizers first
                log "    Removing finalizers from $scan_name..."
                if oc patch compliancescan.compliance.openshift.io/"$scan_name" -n "$namespace" --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null 2>&1; then
                    log "      ✓ Finalizers removed"
                else
                    warning "      Failed to remove finalizers (may not have any)"
                fi
                
                # Then delete the scan
                log "    Deleting ComplianceScan $scan_name..."
                if oc delete compliancescan.compliance.openshift.io "$scan_name" -n "$namespace" --timeout=60s &>/dev/null 2>&1; then
                    log "      ✓ Deleted ComplianceScan $scan_name"
                else
                    warning "      Failed to delete ComplianceScan $scan_name (may already be deleting)"
                fi
            fi
        done
    else
        log "  No ComplianceScan resources found in namespace $namespace"
    fi
}

# Namespace definitions
RHACS_NAMESPACE="rhacs-operator"
CLUSTER_OBSERVABILITY_NS="openshift-cluster-observability-operator"
COMPLIANCE_NAMESPACE="openshift-compliance"

# Delete RHACS custom resources
log "Deleting RHACS custom resources..."
if oc get namespace "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    log "  Processing namespace: $RHACS_NAMESPACE"
    
    # Delete Central resources
    delete_all_resources "central.platform.stackrox.io" "$RHACS_NAMESPACE" "Central"
    
    # Delete SecuredCluster resources
    delete_all_resources "securedcluster.platform.stackrox.io" "$RHACS_NAMESPACE" "SecuredCluster"
    
    # Delete monitoring resources (Cluster Observability Operator)
    delete_resource "monitoringstack" "rhacs-monitoring-stack" "$RHACS_NAMESPACE" "MonitoringStack"
    delete_resource "scrapeconfig" "rhacs-scrape-config" "$RHACS_NAMESPACE" "ScrapeConfig"
    delete_resource "prometheus" "rhacs-prometheus-server" "$RHACS_NAMESPACE" "Prometheus"
    delete_resource "prometheusrule" "rhacs-health-alerts" "$RHACS_NAMESPACE" "PrometheusRule"
    
    # Delete Perses resources
    delete_resource "datasource" "rhacs-datasource" "$RHACS_NAMESPACE" "Perses Datasource"
    delete_resource "dashboard" "rhacs-dashboard" "$RHACS_NAMESPACE" "Perses Dashboard"
    
    # Delete Perses UI Plugin (may be cluster-scoped)
    if oc get uiplugin "rhacs-perses-ui-plugin" &>/dev/null 2>&1; then
        log "  Deleting Perses UI Plugin (cluster-scoped)..."
        oc delete uiplugin "rhacs-perses-ui-plugin" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted Perses UI Plugin" || warning "    Failed to delete Perses UI Plugin"
    fi
    
    # Delete RHACS declarative configuration ConfigMap
    delete_resource "configmap" "rhacs-declarative-config" "$RHACS_NAMESPACE" "RHACS Declarative Config"
    
    # Delete TLS certificates created for RHACS
    log "  Deleting TLS certificates..."
    delete_resource "certificate" "rhacs-central-tls" "$RHACS_NAMESPACE" "RHACS Central TLS Certificate"
    delete_resource "secret" "central-default-tls-cert" "$RHACS_NAMESPACE" "Central TLS Secret"
    delete_resource "secret" "sample-rhacs-operator-prometheus-tls" "$RHACS_NAMESPACE" "Prometheus TLS Secret"
    
    log ""
else
    log "  Namespace $RHACS_NAMESPACE not found (skipping)"
    log ""
fi

# Delete RHACS resources in other namespaces (if any)
log "Checking for RHACS resources in other namespaces..."
CENTRAL_IN_OTHER_NS=$(oc get central.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | grep -v "^${RHACS_NAMESPACE}" || echo "")
SECURED_IN_OTHER_NS=$(oc get securedcluster.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | grep -v "^${RHACS_NAMESPACE}" || echo "")

if [ -n "$CENTRAL_IN_OTHER_NS" ] || [ -n "$SECURED_IN_OTHER_NS" ]; then
    log "  Found RHACS resources in other namespaces, deleting..."
    
    # Get unique namespaces
    OTHER_NS=$(echo -e "$CENTRAL_IN_OTHER_NS\n$SECURED_IN_OTHER_NS" | awk '{print $1}' | sort -u)
    
    for ns in $OTHER_NS; do
        if [ -n "$ns" ] && [ "$ns" != "$RHACS_NAMESPACE" ]; then
            log "  Processing namespace: $ns"
            delete_all_resources "central.platform.stackrox.io" "$ns" "Central"
            delete_all_resources "securedcluster.platform.stackrox.io" "$ns" "SecuredCluster"
        fi
    done
    log ""
fi

# Compliance Operator namespace
COMPLIANCE_NAMESPACE="openshift-compliance"

# Delete Compliance Operator custom resources
log "Deleting Compliance Operator custom resources..."
if oc get namespace "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
    log "  Processing namespace: $COMPLIANCE_NAMESPACE"
    
    # Delete ScanConfigurations
    delete_all_resources "scanconfiguration" "$COMPLIANCE_NAMESPACE" "ScanConfiguration"
    
    # Delete ComplianceScans (with finalizer removal)
    delete_compliance_scans "$COMPLIANCE_NAMESPACE"
    
    # Delete ProfileBundles (optional - may be managed by operator)
    delete_all_resources "profilebundle" "$COMPLIANCE_NAMESPACE" "ProfileBundle"
    
    log ""
else
    log "  Namespace $COMPLIANCE_NAMESPACE not found (skipping)"
    log ""
fi

# Delete ComplianceScans in other namespaces (if any)
log "Checking for ComplianceScans in other namespaces..."
SCANS_IN_OTHER_NS=$(oc get compliancescan.compliance.openshift.io --all-namespaces --no-headers 2>/dev/null | grep -v "^${COMPLIANCE_NAMESPACE}" || echo "")

if [ -n "$SCANS_IN_OTHER_NS" ]; then
    log "  Found ComplianceScans in other namespaces, deleting..."
    
    # Get unique namespaces
    OTHER_NS=$(echo "$SCANS_IN_OTHER_NS" | awk '{print $1}' | sort -u)
    
    for ns in $OTHER_NS; do
        if [ -n "$ns" ] && [ "$ns" != "$COMPLIANCE_NAMESPACE" ]; then
            log "  Processing namespace: $ns"
            delete_compliance_scans "$ns"
        fi
    done
    log ""
fi

log ""
log "========================================================="
log "Step 2: Deleting operator subscriptions and OperatorGroups"
log "========================================================="
log ""

# Function to delete OperatorGroup
delete_operatorgroup() {
    local namespace=$1
    local og_name="${2:-}"
    
    if [ -z "$og_name" ]; then
        # Delete all OperatorGroups in the namespace
        local ogs=$(oc get operatorgroup -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$ogs" ]; then
            for og in $ogs; do
                log "  Deleting OperatorGroup $og in namespace $namespace..."
                oc delete operatorgroup "$og" -n "$namespace" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete OperatorGroup $og"
            done
        else
            log "  No OperatorGroups found in namespace $namespace"
        fi
    else
        # Delete specific OperatorGroup
        if oc get operatorgroup "$og_name" -n "$namespace" &>/dev/null 2>&1; then
            log "  Deleting OperatorGroup $og_name in namespace $namespace..."
            oc delete operatorgroup "$og_name" -n "$namespace" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete OperatorGroup $og_name"
        else
            log "  OperatorGroup $og_name not found in namespace $namespace"
        fi
    fi
}

# Delete OperatorGroups first (before subscriptions)
log "Deleting OperatorGroups..."

# Delete RHACS OperatorGroup
log "Deleting RHACS OperatorGroup..."
delete_operatorgroup "$RHACS_NAMESPACE" "rhacs-operator-group"

# Delete Cluster Observability OperatorGroup
log "Deleting Cluster Observability OperatorGroup..."
delete_operatorgroup "$CLUSTER_OBSERVABILITY_NS" "cluster-observability-og"

# Delete Compliance OperatorGroup
log "Deleting Compliance OperatorGroup..."
delete_operatorgroup "$COMPLIANCE_NAMESPACE" "openshift-compliance"

log ""
log "Waiting for OperatorGroups to be deleted..."
sleep 5

log ""
log "Deleting operator subscriptions..."

# Delete RHACS operator subscription
log "Deleting RHACS operator subscription..."
if oc get subscription.operators.coreos.com rhacs-operator -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    log "  Deleting subscription rhacs-operator in namespace $RHACS_NAMESPACE..."
    oc delete subscription.operators.coreos.com rhacs-operator -n "$RHACS_NAMESPACE" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete"
else
    log "  Subscription rhacs-operator not found in $RHACS_NAMESPACE"
fi

# Delete Cluster Observability Operator subscription
log "Deleting Cluster Observability Operator subscription..."
if oc get subscription.operators.coreos.com cluster-observability-operator -n "$CLUSTER_OBSERVABILITY_NS" &>/dev/null 2>&1; then
    log "  Deleting subscription cluster-observability-operator in namespace $CLUSTER_OBSERVABILITY_NS..."
    oc delete subscription.operators.coreos.com cluster-observability-operator -n "$CLUSTER_OBSERVABILITY_NS" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete"
else
    log "  Subscription cluster-observability-operator not found in $CLUSTER_OBSERVABILITY_NS"
fi

# Delete Compliance Operator subscription
log "Deleting Compliance Operator subscription..."
if oc get subscription.operators.coreos.com compliance-operator -n "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
    log "  Deleting subscription compliance-operator in namespace $COMPLIANCE_NAMESPACE..."
    oc delete subscription.operators.coreos.com compliance-operator -n "$COMPLIANCE_NAMESPACE" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete"
else
    log "  Subscription compliance-operator not found in $COMPLIANCE_NAMESPACE"
fi

# Note: Cert-Manager is NOT deleted as it may be used by other components

log ""
log "Waiting for subscriptions to be deleted..."
sleep 10

log ""
log "========================================================="
log "Step 3: Deleting demo applications"
log "========================================================="
log ""

# Delete all demo applications with label demo=roadshow
DEMO_LABEL="demo=roadshow"
log "Deleting demo applications with label $DEMO_LABEL..."

# Get all namespaces with demo applications
DEMO_NAMESPACES=$(oc get deployments -l "$DEMO_LABEL" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u || echo "")

if [ -n "$DEMO_NAMESPACES" ]; then
    log "  Found demo applications in namespaces:"
    for ns in $DEMO_NAMESPACES; do
        log "    - $ns"
    done
    
    # Delete all resources with demo label in each namespace
    for namespace in $DEMO_NAMESPACES; do
        log "  Deleting demo resources in namespace: $namespace"
        
        # Delete all resources with the demo label using oc delete all
        log "    Deleting all resources with label $DEMO_LABEL..."
        set +e  # Temporarily disable exit on error
        oc delete all -l "$DEMO_LABEL" -n "$namespace" --timeout=60s &>/dev/null 2>&1 && log "      ✓ Deleted all resources" || warning "      Some resources may not have been deleted"
        
        # Also delete configmaps and secrets with the label (not included in 'oc delete all')
        oc delete configmap -l "$DEMO_LABEL" -n "$namespace" --timeout=60s &>/dev/null 2>&1 || true
        oc delete secret -l "$DEMO_LABEL" -n "$namespace" --timeout=60s &>/dev/null 2>&1 || true
        set -e  # Re-enable exit on error
    done
    
    log ""
    log "Waiting for demo application deletions to complete..."
    sleep 10
else
    log "  No demo applications found with label $DEMO_LABEL"
    log ""
fi

log ""
log "========================================================="
log "Step 4: Deleting namespaces"
log "========================================================="
log ""

# Function to delete namespace
delete_namespace() {
    local namespace=$1
    
    if oc get namespace "$namespace" &>/dev/null 2>&1; then
        log "  Deleting namespace: $namespace"
        if oc delete namespace "$namespace" --timeout=120s &>/dev/null 2>&1; then
            log "    ✓ Namespace deletion initiated"
            return 0
        else
            warning "    Failed to delete namespace $namespace (may already be deleting)"
            return 1
        fi
    else
        log "  Namespace $namespace not found (skipping)"
        return 0
    fi
}

# Delete namespaces (non-fatal - continue even if some fail)
set +e  # Temporarily disable exit on error for namespace deletion
delete_namespace "$RHACS_NAMESPACE" || true
delete_namespace "$CLUSTER_OBSERVABILITY_NS" || true
delete_namespace "$COMPLIANCE_NAMESPACE" || true
# Note: cert-manager-operator namespace is NOT deleted as cert-manager may be used by other components
set -e  # Re-enable exit on error

log ""
log "Waiting for namespace deletions to begin..."
sleep 15

# Function to force delete namespace by removing finalizers
force_delete_namespace() {
    local namespace=$1
    
    if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
        # Namespace doesn't exist, already deleted
        return 0
    fi
    
    NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    # Get current finalizers (check both spec and metadata)
    FINALIZERS=$(oc get namespace "$namespace" -o jsonpath='{.spec.finalizers[*]}' 2>/dev/null || echo "")
    if [ -z "$FINALIZERS" ]; then
        FINALIZERS=$(oc get namespace "$namespace" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
    fi
    
    # If namespace is not Terminating and has no finalizers, try normal deletion first
    if [ "$NS_PHASE" != "Terminating" ] && [ -z "$FINALIZERS" ]; then
        log "  Namespace $namespace is not terminating and has no finalizers - attempting normal deletion..."
        if oc delete namespace "$namespace" --timeout=60s &>/dev/null 2>&1; then
            sleep 5
            if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
                log "    ✓ Namespace deleted successfully"
                return 0
            fi
        fi
    fi
    
    # If namespace has finalizers or is stuck, proceed with force deletion
    if [ -n "$FINALIZERS" ]; then
        log "  Namespace $namespace has finalizers: $FINALIZERS - force deleting..."
    elif [ "$NS_PHASE" = "Terminating" ]; then
        log "  Namespace $namespace is stuck in Terminating state - force deleting..."
    else
        # Namespace exists but isn't terminating and has no finalizers - should delete normally
        return 0
    fi
    
    # Method 1: Try simple patch methods first (metadata.finalizers)
    if oc patch namespace "$namespace" --type merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null 2>&1; then
        log "    ✓ Finalizers removed via merge patch (metadata) - namespace should complete deletion"
        sleep 2
        if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Method 2: Try patching spec.finalizers
    if oc patch namespace "$namespace" --type merge -p '{"spec":{"finalizers":[]}}' &>/dev/null 2>&1; then
        log "    ✓ Finalizers removed via merge patch (spec) - namespace should complete deletion"
        sleep 2
        if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Method 3: Try JSON patch
    if oc patch namespace "$namespace" --type json -p='[{"op": "replace", "path": "/metadata/finalizers", "value": []}]' &>/dev/null 2>&1; then
        log "    ✓ Finalizers removed via JSON patch - namespace should complete deletion"
        sleep 2
        if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Method 4: Try direct edit with jq
    if command -v jq &>/dev/null; then
        if oc get namespace "$namespace" -o json | jq 'del(.metadata.finalizers) | del(.spec.finalizers)' | oc replace -f - &>/dev/null 2>&1; then
            log "    ✓ Finalizers removed via direct edit - namespace should complete deletion"
            sleep 2
            if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    
    # Method 5: Use oc proxy and direct API call (most robust)
    warning "    Standard methods failed, using oc proxy method..."
    
    # Create temporary directory for JSON files
    TMP_DIR=$(mktemp -d)
    local PROXY_PID=""
    
    # Cleanup function
    cleanup_proxy() {
        if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
            kill "$PROXY_PID" 2>/dev/null || true
            wait "$PROXY_PID" 2>/dev/null || true
        fi
        rm -rf "$TMP_DIR" 2>/dev/null || true
    }
    trap cleanup_proxy EXIT
    
    log "    Exporting namespace JSON..."
    oc get namespace "$namespace" -o json > "$TMP_DIR/ns-${namespace}.json" 2>/dev/null || {
        warning "    Failed to export namespace JSON"
        cleanup_proxy
        return 1
    }
    
    log "    Removing finalizers from JSON..."
    if command -v jq &>/dev/null; then
        # Remove both metadata.finalizers and spec.finalizers
        jq 'del(.metadata.finalizers) | del(.spec.finalizers)' "$TMP_DIR/ns-${namespace}.json" > "$TMP_DIR/ns-${namespace}-patched.json" 2>/dev/null || {
            warning "    Failed to patch JSON with jq"
            cleanup_proxy
            return 1
        }
    else
        # Fallback: use sed (less safe)
        sed 's/"finalizers": \[[^]]*\]/"finalizers": []/g' "$TMP_DIR/ns-${namespace}.json" > "$TMP_DIR/ns-${namespace}-patched.json" 2>/dev/null || \
        sed 's/"finalizers":\[[^]]*\]/"finalizers":[]/g' "$TMP_DIR/ns-${namespace}.json" > "$TMP_DIR/ns-${namespace}-patched.json" 2>/dev/null || {
            warning "    Failed to patch JSON with sed"
            cleanup_proxy
            return 1
        }
    fi
    
    log "    Starting oc proxy..."
    oc proxy > /dev/null 2>&1 &
    PROXY_PID=$!
    sleep 3  # Give proxy a moment to start
    
    # Verify proxy is running
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        warning "    Failed to start oc proxy"
        cleanup_proxy
        return 1
    fi
    
    log "    Applying patched finalizers via direct API call..."
    PROXY_URL="http://127.0.0.1:8001/api/v1/namespaces/${namespace}/finalize"
    
    CURL_OUTPUT=$(curl -k -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -X PUT \
        --data-binary @"$TMP_DIR/ns-${namespace}-patched.json" \
        "$PROXY_URL" 2>&1 || echo "")
    
    HTTP_CODE=$(echo "$CURL_OUTPUT" | tail -1)
    RESPONSE_BODY=$(echo "$CURL_OUTPUT" | sed '$d')
    
    cleanup_proxy
    trap - EXIT
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "202" ]; then
        log "    ✓ Finalizers removed successfully via API (HTTP $HTTP_CODE) - namespace should complete deletion"
        # Wait a bit and check if namespace is gone
        sleep 5
        if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
            log "    ✓ Namespace successfully deleted!"
            return 0
        fi
        return 0
    else
        warning "    Failed to remove finalizers via API (HTTP $HTTP_CODE)"
        if [ -n "$RESPONSE_BODY" ]; then
            warning "    Response: ${RESPONSE_BODY:0:200}"
        fi
        return 1
    fi
}

log ""
log "Checking for namespaces that need force deletion..."
log "This includes namespaces stuck in Terminating state or with finalizers..."

# Function to check if namespace needs force deletion
namespace_needs_force_delete() {
    local namespace=$1
    
    if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
        return 1  # Namespace doesn't exist, no force delete needed
    fi
    
    NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    # Check for finalizers in both metadata and spec
    FINALIZERS_META=$(oc get namespace "$namespace" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
    FINALIZERS_SPEC=$(oc get namespace "$namespace" -o jsonpath='{.spec.finalizers[*]}' 2>/dev/null || echo "")
    
    # Need force delete if: Terminating state OR has finalizers
    if [ "$NS_PHASE" = "Terminating" ] || [ -n "$FINALIZERS_META" ] || [ -n "$FINALIZERS_SPEC" ]; then
        return 0  # Needs force delete
    fi
    
    return 1  # Doesn't need force delete
}

# Force delete namespaces that are stuck or have finalizers
set +e  # Temporarily disable exit on error

if namespace_needs_force_delete "$RHACS_NAMESPACE"; then
    log "  Force deleting namespace: $RHACS_NAMESPACE"
    force_delete_namespace "$RHACS_NAMESPACE" || true
fi

if namespace_needs_force_delete "$CLUSTER_OBSERVABILITY_NS"; then
    log "  Force deleting namespace: $CLUSTER_OBSERVABILITY_NS"
    force_delete_namespace "$CLUSTER_OBSERVABILITY_NS" || true
fi

if namespace_needs_force_delete "$COMPLIANCE_NAMESPACE"; then
    log "  Force deleting namespace: $COMPLIANCE_NAMESPACE"
    force_delete_namespace "$COMPLIANCE_NAMESPACE" || true
fi

set -e  # Re-enable exit on error

log ""
log "Waiting for force-deleted namespaces to complete deletion..."
sleep 10

log ""
log "========================================================="
log "Step 5: Verifying cleanup"
log "========================================================="
log ""

# Function to verify namespace deletion
verify_namespace_deletion() {
    local namespace=$1
    
    if oc get namespace "$namespace" &>/dev/null 2>&1; then
        NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$NS_PHASE" = "Terminating" ]; then
            log "  ✓ Namespace $namespace is terminating (deletion in progress - this is normal)"
            return 0  # Terminating is success - deletion was initiated
        else
            warning "  Namespace $namespace still exists (phase: $NS_PHASE)"
            return 1
        fi
    else
        log "  ✓ Namespace $namespace has been deleted"
        return 0
    fi
}

# Verify namespace deletions
log "Verifying namespace deletions..."
ALL_DELETED=true

verify_namespace_deletion "$RHACS_NAMESPACE" || ALL_DELETED=false
verify_namespace_deletion "$CLUSTER_OBSERVABILITY_NS" || ALL_DELETED=false
verify_namespace_deletion "$COMPLIANCE_NAMESPACE" || ALL_DELETED=false
# Note: cert-manager-operator namespace is NOT verified as it's not being deleted

log ""
log "Verifying custom resources are deleted..."

# Check for remaining RHACS resources
REMAINING_CENTRAL=$(oc get central.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
REMAINING_CENTRAL=$(echo "$REMAINING_CENTRAL" | tr -d '[:space:]')
REMAINING_CENTRAL=$((REMAINING_CENTRAL + 0))

REMAINING_SECURED=$(oc get securedcluster.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
REMAINING_SECURED=$(echo "$REMAINING_SECURED" | tr -d '[:space:]')
REMAINING_SECURED=$((REMAINING_SECURED + 0))

if [ "$REMAINING_CENTRAL" -gt 0 ] || [ "$REMAINING_SECURED" -gt 0 ]; then
    warning "  Found remaining RHACS resources: Central=$REMAINING_CENTRAL, SecuredCluster=$REMAINING_SECURED"
    ALL_DELETED=false
else
    log "  ✓ No remaining RHACS custom resources"
fi

# Check for remaining monitoring resources (if namespace still exists)
if oc get namespace "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    REMAINING_MONITORING=$(oc get monitoringstack,scrapeconfig,prometheus,prometheusrule,datasource,dashboard -n "$RHACS_NAMESPACE" --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
    REMAINING_MONITORING=$(echo "$REMAINING_MONITORING" | tr -d '[:space:]')
    REMAINING_MONITORING=$((REMAINING_MONITORING + 0))
    
    if [ "$REMAINING_MONITORING" -gt 0 ]; then
        warning "  Found remaining monitoring resources: $REMAINING_MONITORING"
        ALL_DELETED=false
    else
        log "  ✓ No remaining monitoring resources"
    fi
fi

# Check for remaining compliance resources (if namespace still exists)
if oc get namespace "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
    REMAINING_COMPLIANCE=$(oc get scanconfiguration,compliancescan -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
    REMAINING_COMPLIANCE=$(echo "$REMAINING_COMPLIANCE" | tr -d '[:space:]')
    REMAINING_COMPLIANCE=$((REMAINING_COMPLIANCE + 0))
    
    if [ "$REMAINING_COMPLIANCE" -gt 0 ]; then
        warning "  Found remaining compliance resources: $REMAINING_COMPLIANCE"
        ALL_DELETED=false
    else
        log "  ✓ No remaining compliance resources"
    fi
fi

# Check for remaining subscriptions (excluding cert-manager)
REMAINING_SUBS=$(oc get subscription.operators.coreos.com --all-namespaces --no-headers 2>/dev/null | grep -E "(rhacs-operator|cluster-observability-operator|compliance-operator)" | wc -l 2>/dev/null || echo "0")
REMAINING_SUBS=$(echo "$REMAINING_SUBS" | tr -d '[:space:]')
# Handle empty string or non-numeric values
if [ -z "$REMAINING_SUBS" ] || [ "$REMAINING_SUBS" = "" ]; then
    REMAINING_SUBS="0"
fi
# Convert to integer for comparison (handles "00" -> "0")
REMAINING_SUBS=$((REMAINING_SUBS + 0))

if [ "$REMAINING_SUBS" -gt 0 ]; then
    warning "  Found remaining operator subscriptions: $REMAINING_SUBS"
    ALL_DELETED=false
else
    log "  ✓ No remaining operator subscriptions (cert-manager excluded)"
fi

# Check for remaining OperatorGroups
log "Verifying OperatorGroups are deleted..."
REMAINING_OGS=0

# Check RHACS OperatorGroup
if oc get namespace "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    OG_COUNT=$(oc get operatorgroup -n "$RHACS_NAMESPACE" --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
    OG_COUNT=$(echo "$OG_COUNT" | tr -d '[:space:]')
    OG_COUNT=$((OG_COUNT + 0))
    REMAINING_OGS=$((REMAINING_OGS + OG_COUNT))
fi

# Check Cluster Observability OperatorGroup
if oc get namespace "$CLUSTER_OBSERVABILITY_NS" &>/dev/null 2>&1; then
    OG_COUNT=$(oc get operatorgroup -n "$CLUSTER_OBSERVABILITY_NS" --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
    OG_COUNT=$(echo "$OG_COUNT" | tr -d '[:space:]')
    OG_COUNT=$((OG_COUNT + 0))
    REMAINING_OGS=$((REMAINING_OGS + OG_COUNT))
fi

# Check Compliance OperatorGroup
if oc get namespace "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
    OG_COUNT=$(oc get operatorgroup -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
    OG_COUNT=$(echo "$OG_COUNT" | tr -d '[:space:]')
    OG_COUNT=$((OG_COUNT + 0))
    REMAINING_OGS=$((REMAINING_OGS + OG_COUNT))
fi

if [ "$REMAINING_OGS" -gt 0 ]; then
    warning "  Found remaining OperatorGroups: $REMAINING_OGS"
    ALL_DELETED=false
else
    log "  ✓ No remaining OperatorGroups"
fi

# Check for remaining demo applications
REMAINING_DEMO=$(oc get deployments -l "$DEMO_LABEL" -A --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
REMAINING_DEMO=$(echo "$REMAINING_DEMO" | tr -d '[:space:]')
REMAINING_DEMO=$((REMAINING_DEMO + 0))

if [ "$REMAINING_DEMO" -gt 0 ]; then
    warning "  Found remaining demo applications: $REMAINING_DEMO"
    ALL_DELETED=false
else
    log "  ✓ No remaining demo applications"
fi

log ""
log "========================================================="
if [ "$ALL_DELETED" = true ]; then
    log "✓ Cleanup completed successfully!"
    log "========================================================="
    log ""
    log "All resources have been deleted:"
    log "  ✓ RHACS operator and custom resources"
    log "  ✓ Cluster Observability Operator and monitoring resources"
    log "  ✓ Compliance Operator and resources"
    log "  ✓ OperatorGroups"
    log "  ✓ Operator subscriptions"
    log "  ✓ Demo applications (demo=roadshow)"
    log "  ✓ All namespaces (except cert-manager-operator)"
    log ""
else
    log "⚠ Cleanup completed with warnings"
    log "========================================================="
    log ""
    log "Some resources may still be terminating:"
    log "  - Namespaces may take a few minutes to fully delete"
    log "  - Finalizers may delay resource deletion"
    log ""
    log "To check remaining resources:"
    log "  oc get namespaces | grep -E '(rhacs-operator|openshift-cluster-observability|openshift-compliance)'"
    log "  oc get central,securedcluster --all-namespaces"
    log "  oc get subscription --all-namespaces | grep -E '(rhacs|observability|compliance)'"
    log "  oc get operatorgroup --all-namespaces | grep -E '(rhacs|observability|compliance)'"
    log "  oc get deployments -l demo=roadshow -A"
    log ""
fi

log "Cleanup script completed!"
log ""

