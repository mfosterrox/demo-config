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

# RHACS namespace
RHACS_NAMESPACE="rhacs-operator"

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
    
    # Delete ComplianceScans
    delete_all_resources "compliancescan" "$COMPLIANCE_NAMESPACE" "ComplianceScan"
    
    # Delete ProfileBundles (optional - may be managed by operator)
    delete_all_resources "profilebundle" "$COMPLIANCE_NAMESPACE" "ProfileBundle"
    
    log ""
else
    log "  Namespace $COMPLIANCE_NAMESPACE not found (skipping)"
    log ""
fi

log ""
log "========================================================="
log "Step 2: Deleting operator subscriptions"
log "========================================================="
log ""

# Delete RHACS operator subscription
log "Deleting RHACS operator subscription..."
if oc get subscription.operators.coreos.com rhacs-operator -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    log "  Deleting subscription rhacs-operator in namespace $RHACS_NAMESPACE..."
    oc delete subscription.operators.coreos.com rhacs-operator -n "$RHACS_NAMESPACE" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete"
else
    log "  Subscription rhacs-operator not found in $RHACS_NAMESPACE"
fi

# Delete Cluster Observability Operator subscription
CLUSTER_OBSERVABILITY_NS="openshift-cluster-observability-operator"
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

# Delete Cert-Manager operator subscription (if installed by our scripts)
CERT_MANAGER_NS="cert-manager-operator"
log "Deleting Cert-Manager operator subscription..."
if oc get subscription.operators.coreos.com cert-manager -n "$CERT_MANAGER_NS" &>/dev/null 2>&1; then
    log "  Deleting subscription cert-manager in namespace $CERT_MANAGER_NS..."
    oc delete subscription.operators.coreos.com cert-manager -n "$CERT_MANAGER_NS" --timeout=60s &>/dev/null 2>&1 && log "    ✓ Deleted" || warning "    Failed to delete"
else
    log "  Subscription cert-manager not found in $CERT_MANAGER_NS (may not have been installed by our scripts)"
fi

log ""
log "Waiting for subscriptions to be deleted..."
sleep 10

log ""
log "========================================================="
log "Step 3: Deleting namespaces"
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
delete_namespace "$CERT_MANAGER_NS" || true
set -e  # Re-enable exit on error

log ""
log "Waiting for namespace deletions to begin..."
sleep 15

log ""
log "========================================================="
log "Step 4: Verifying cleanup"
log "========================================================="
log ""

# Function to verify namespace deletion
verify_namespace_deletion() {
    local namespace=$1
    
    if oc get namespace "$namespace" &>/dev/null 2>&1; then
        NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$NS_PHASE" = "Terminating" ]; then
            warning "  Namespace $namespace is still terminating (deletion in progress)"
            return 1
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
verify_namespace_deletion "$CERT_MANAGER_NS" || ALL_DELETED=false

log ""
log "Verifying custom resources are deleted..."

# Check for remaining RHACS resources
REMAINING_CENTRAL=$(oc get central.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
REMAINING_SECURED=$(oc get securedcluster.platform.stackrox.io --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")

if [ "$REMAINING_CENTRAL" != "0" ] || [ "$REMAINING_SECURED" != "0" ]; then
    warning "  Found remaining RHACS resources: Central=$REMAINING_CENTRAL, SecuredCluster=$REMAINING_SECURED"
    ALL_DELETED=false
else
    log "  ✓ No remaining RHACS custom resources"
fi

# Check for remaining monitoring resources (if namespace still exists)
if oc get namespace "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
    REMAINING_MONITORING=$(oc get monitoringstack,scrapeconfig,prometheus,prometheusrule,datasource,dashboard -n "$RHACS_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    if [ "$REMAINING_MONITORING" != "0" ]; then
        warning "  Found remaining monitoring resources: $REMAINING_MONITORING"
        ALL_DELETED=false
    else
        log "  ✓ No remaining monitoring resources"
    fi
fi

# Check for remaining compliance resources (if namespace still exists)
if oc get namespace "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
    REMAINING_COMPLIANCE=$(oc get scanconfiguration,compliancescan -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    if [ "$REMAINING_COMPLIANCE" != "0" ]; then
        warning "  Found remaining compliance resources: $REMAINING_COMPLIANCE"
        ALL_DELETED=false
    else
        log "  ✓ No remaining compliance resources"
    fi
fi

# Check for remaining subscriptions
REMAINING_SUBS=$(oc get subscription.operators.coreos.com --all-namespaces --no-headers 2>/dev/null | grep -E "(rhacs-operator|cluster-observability-operator|compliance-operator|cert-manager)" | wc -l | tr -d '[:space:]' || echo "0")
if [ "$REMAINING_SUBS" != "0" ]; then
    warning "  Found remaining operator subscriptions: $REMAINING_SUBS"
    ALL_DELETED=false
else
    log "  ✓ No remaining operator subscriptions"
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
    log "  ✓ Cert-Manager operator (if installed)"
    log "  ✓ All namespaces"
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
    log "  oc get namespaces | grep -E '(rhacs-operator|openshift-cluster-observability|openshift-compliance|cert-manager)'"
    log "  oc get central,securedcluster --all-namespaces"
    log "  oc get subscription --all-namespaces | grep -E '(rhacs|observability|compliance|cert-manager)'"
    log ""
fi

log "Cleanup script completed!"
log ""

