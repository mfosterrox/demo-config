#!/bin/bash
# Perses Monitoring Cleanup Script
# Removes all resources created by 04-setup-perses-monitoring.sh

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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
if ! oc auth can-i delete subscriptions --all-namespaces; then
    warning "Cluster admin privileges recommended for cleanup. Current user: $(oc whoami)"
    warning "Some resources may not be deleted without proper permissions."
fi
log "✓ Privileges checked"

log "Prerequisites validated successfully"

# Load NAMESPACE from ~/.bashrc (set by previous scripts)
NAMESPACE=$(load_from_bashrc "NAMESPACE")
if [ -z "$NAMESPACE" ]; then
    NAMESPACE="tssc-acs"
    log "NAMESPACE not found in ~/.bashrc, using default: $NAMESPACE"
else
    log "✓ Loaded NAMESPACE from ~/.bashrc: $NAMESPACE"
fi

OPERATOR_NAMESPACE="openshift-cluster-observability-operator"

log ""
log "========================================================="
log "Perses Monitoring Cleanup"
log "========================================================="
log "This script will remove all resources created by 04-setup-perses-monitoring.sh"
log "Namespace: $NAMESPACE"
log "Operator Namespace: $OPERATOR_NAMESPACE"
log "========================================================="
log ""

# Step 1: Remove Perses resources
log ""
log "========================================================="
log "Step 1: Removing Perses resources"
log "========================================================="

# Remove Perses Dashboard
log "Removing Perses Dashboard..."
if oc get dashboard rhacs-dashboard -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete dashboard rhacs-dashboard -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed dashboard" || warning "  Failed to remove dashboard"
else
    log "  Dashboard not found (may already be removed)"
fi

# Remove Perses Datasource
log "Removing Perses Datasource..."
if oc get datasource rhacs-datasource -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete datasource rhacs-datasource -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed datasource" || warning "  Failed to remove datasource"
else
    log "  Datasource not found (may already be removed)"
fi

# Remove Perses UI Plugin (may be cluster-scoped)
log "Removing Perses UI Plugin..."
if oc get uiplugin perses-ui-plugin >/dev/null 2>&1; then
    oc delete uiplugin perses-ui-plugin 2>/dev/null && log "  ✓ Removed UI plugin" || warning "  Failed to remove UI plugin"
else
    log "  UI plugin not found (may already be removed)"
fi

log "✓ Perses resources cleanup completed"

# Step 2: Remove RHACS declarative configuration
log ""
log "========================================================="
log "Step 2: Removing RHACS declarative configuration"
log "========================================================="

log "Removing RHACS declarative configuration ConfigMap..."
if oc get configmap rhacs-declarative-config -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete configmap rhacs-declarative-config -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed ConfigMap" || warning "  Failed to remove ConfigMap"
else
    log "  ConfigMap not found (may already be removed)"
fi

log "✓ RHACS declarative configuration cleanup completed"

# Step 3: Remove Prometheus Operator resources
log ""
log "========================================================="
log "Step 3: Removing Prometheus Operator resources"
log "========================================================="

# Remove PrometheusRule
log "Removing PrometheusRule..."
if oc get prometheusrule rhacs-health-alerts -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete prometheusrule rhacs-health-alerts -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed PrometheusRule" || warning "  Failed to remove PrometheusRule"
else
    log "  PrometheusRule not found (may already be removed)"
fi

# Remove Prometheus
log "Removing Prometheus..."
if oc get prometheus rhacs-prometheus-server -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete prometheus rhacs-prometheus-server -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed Prometheus" || warning "  Failed to remove Prometheus"
    # Wait for Prometheus to be fully deleted
    log "  Waiting for Prometheus to be fully deleted..."
    sleep 5
else
    log "  Prometheus not found (may already be removed)"
fi

# Remove Prometheus additional scrape config secret
log "Removing Prometheus additional scrape config secret..."
if oc get secret prometheus-additional-scrape-config -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete secret prometheus-additional-scrape-config -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed secret" || warning "  Failed to remove secret"
else
    log "  Secret not found (may already be removed)"
fi

log "✓ Prometheus Operator resources cleanup completed"

# Step 4: Remove Cluster Observability Operator resources
log ""
log "========================================================="
log "Step 4: Removing Cluster Observability Operator resources"
log "========================================================="

# Remove ScrapeConfig
log "Removing ScrapeConfig..."
if oc get scrapeconfig rhacs-scrape-config -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete scrapeconfig rhacs-scrape-config -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed ScrapeConfig" || warning "  Failed to remove ScrapeConfig"
else
    log "  ScrapeConfig not found (may already be removed)"
fi

# Remove MonitoringStack
log "Removing MonitoringStack..."
if oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed MonitoringStack" || warning "  Failed to remove MonitoringStack"
    # Wait for MonitoringStack to be fully deleted
    log "  Waiting for MonitoringStack to be fully deleted..."
    sleep 5
else
    log "  MonitoringStack not found (may already be removed)"
fi

log "✓ Cluster Observability Operator resources cleanup completed"

# Step 5: Remove TLS secret
log ""
log "========================================================="
log "Step 5: Removing TLS secret"
log "========================================================="

log "Removing TLS secret..."
if oc get secret rhacs-prometheus-tls -n "$NAMESPACE" >/dev/null 2>&1; then
    oc delete secret rhacs-prometheus-tls -n "$NAMESPACE" 2>/dev/null && log "  ✓ Removed TLS secret" || warning "  Failed to remove TLS secret"
else
    log "  TLS secret not found (may already be removed)"
fi

log "✓ TLS secret cleanup completed"

# Step 6: Remove UserPKI auth provider from RHACS
log ""
log "========================================================="
log "Step 6: Removing UserPKI auth provider from RHACS"
log "========================================================="

# Load RHACS environment variables
ROX_ENDPOINT=$(load_from_bashrc "ROX_ENDPOINT")
ROX_API_TOKEN=$(load_from_bashrc "ROX_API_TOKEN")

if [ -z "$ROX_ENDPOINT" ] || [ -z "$ROX_API_TOKEN" ]; then
    warning "ROX_ENDPOINT or ROX_API_TOKEN not found in ~/.bashrc"
    warning "Skipping UserPKI auth provider removal"
    warning "You may need to remove it manually: roxctl central userpki delete Prometheus"
else
    # Check if roxctl is available
    if ! command -v roxctl &>/dev/null; then
        log "roxctl not found, checking if it needs to be downloaded..."
        # Try to download roxctl
        if command -v curl &>/dev/null; then
            log "Downloading roxctl..."
            curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl" 2>/dev/null || {
                warning "Failed to download roxctl. Skipping auth provider removal."
                warning "You may need to remove it manually: roxctl central userpki delete Prometheus"
                ROX_ENDPOINT=""
            }
            if [ -f /tmp/roxctl ]; then
                chmod +x /tmp/roxctl
                ROXCTL_CMD="/tmp/roxctl"
                log "✓ roxctl downloaded to /tmp/roxctl"
            fi
        else
            warning "curl not found. Cannot download roxctl. Skipping auth provider removal."
            ROX_ENDPOINT=""
        fi
    else
        ROXCTL_CMD="roxctl"
        log "✓ roxctl found in PATH"
    fi
    
    if [ -n "$ROX_ENDPOINT" ] && [ -n "$ROXCTL_CMD" ]; then
        # Normalize ROX_ENDPOINT for roxctl
        ROX_ENDPOINT_NORMALIZED="$ROX_ENDPOINT"
        if [[ ! "$ROX_ENDPOINT_NORMALIZED" =~ :[0-9]+$ ]]; then
            ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED}:443"
        fi
        
        # Remove https:// prefix if present
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#https://}"
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#http://}"
        
        # Export ROX_API_TOKEN
        export ROX_API_TOKEN
        
        log "Removing UserPKI auth provider 'Prometheus'..."
        
        # Temporarily disable ERR trap since delete may fail if provider doesn't exist
        set +e
        trap '' ERR
        
        # Use printf to send "y\n" to answer the interactive confirmation prompt
        DELETE_OUTPUT=$(timeout 30 bash -c "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"; printf 'y\n' | $ROXCTL_CMD -e \"$ROX_ENDPOINT_NORMALIZED\" \
            central userpki delete Prometheus \
            --insecure-skip-tls-verify 2>&1" 2>&1 || true)
        DELETE_EXIT_CODE=$?
        
        # Re-enable ERR trap
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        # Check if deletion was successful
        if echo "$DELETE_OUTPUT" | grep -qi "context canceled\|Canceled\|deleted\|success\|Deleting provider"; then
            log "  ✓ Removed UserPKI auth provider 'Prometheus'"
        elif echo "$DELETE_OUTPUT" | grep -qi "not found\|does not exist\|No user certificate providers"; then
            log "  UserPKI auth provider 'Prometheus' not found (may already be removed)"
        elif [ $DELETE_EXIT_CODE -eq 0 ]; then
            log "  ✓ Removed UserPKI auth provider 'Prometheus'"
        else
            warning "  Failed to remove UserPKI auth provider. Exit code: $DELETE_EXIT_CODE"
            warning "  Output: ${DELETE_OUTPUT:0:300}"
            warning "  You may need to remove it manually: ROX_API_TOKEN=\"\$ROX_API_TOKEN\" roxctl -e $ROX_ENDPOINT_NORMALIZED central userpki delete Prometheus --insecure-skip-tls-verify"
        fi
    fi
fi

log "✓ UserPKI auth provider cleanup completed"

# Step 7: Remove Cluster Observability Operator
log ""
log "========================================================="
log "Step 7: Removing Cluster Observability Operator"
log "========================================================="

if oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "Removing Cluster Observability Operator subscription..."
    if oc get subscription.operators.coreos.com cluster-observability-operator -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        # Get CSV name before deleting subscription
        CSV_NAME=$(oc get subscription.operators.coreos.com cluster-observability-operator -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        
        oc delete subscription cluster-observability-operator -n "$OPERATOR_NAMESPACE" 2>/dev/null && log "  ✓ Removed subscription" || warning "  Failed to remove subscription"
        
        # Wait for subscription to be deleted
        sleep 3
        
        # Delete CSV if it exists
        if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "null" ]; then
            log "Removing ClusterServiceVersion..."
            if oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                oc delete csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" 2>/dev/null && log "  ✓ Removed CSV" || warning "  Failed to remove CSV"
            fi
        fi
        
        # Delete any remaining CSVs
        log "Checking for remaining CSVs..."
        REMAINING_CSVS=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep cluster-observability-operator || echo "")
        if [ -n "$REMAINING_CSVS" ]; then
            for csv in $REMAINING_CSVS; do
                oc delete csv "$csv" -n "$OPERATOR_NAMESPACE" 2>/dev/null && log "  ✓ Removed CSV: $csv" || warning "  Failed to remove CSV: $csv"
            done
        fi
    else
        log "  Subscription not found (may already be removed)"
    fi
    
    # Remove OperatorGroup
    log "Removing OperatorGroup..."
    if oc get operatorgroup cluster-observability-og -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        oc delete operatorgroup cluster-observability-og -n "$OPERATOR_NAMESPACE" 2>/dev/null && log "  ✓ Removed OperatorGroup" || warning "  Failed to remove OperatorGroup"
    else
        log "  OperatorGroup not found (may already be removed)"
    fi
    
    # Wait for resources to be cleaned up
    log "Waiting for operator resources to be cleaned up..."
    sleep 5
    
    # Check if namespace is empty (except for finalizers)
    log "Checking if namespace can be deleted..."
    RESOURCES=$(oc get all -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -v "No resources found" | wc -l || echo "0")
    if [ "$RESOURCES" -eq 0 ] || [ "$RESOURCES" -eq 1 ]; then
        log "Removing namespace $OPERATOR_NAMESPACE..."
        oc delete namespace "$OPERATOR_NAMESPACE" 2>/dev/null && log "  ✓ Removed namespace" || warning "  Failed to remove namespace (may have finalizers)"
    else
        warning "  Namespace still contains resources. Manual cleanup may be required."
        warning "  Check: oc get all -n $OPERATOR_NAMESPACE"
    fi
else
    log "  Namespace $OPERATOR_NAMESPACE not found (may already be removed)"
fi

log "✓ Cluster Observability Operator cleanup completed"

# Step 8: Clean up temporary certificate files
log ""
log "========================================================="
log "Step 8: Cleaning up temporary files"
log "========================================================="

log "Removing temporary certificate files..."
if [ -f "tls.key" ]; then
    rm -f tls.key && log "  ✓ Removed tls.key" || warning "  Failed to remove tls.key"
else
    log "  tls.key not found"
fi

if [ -f "tls.crt" ]; then
    rm -f tls.crt && log "  ✓ Removed tls.crt" || warning "  Failed to remove tls.crt"
else
    log "  tls.crt not found"
fi

log "✓ Temporary files cleanup completed"

# Final summary
log ""
log "========================================================="
log "Perses Monitoring Cleanup Completed!"
log "========================================================="
log ""
log "Removed resources:"
log "  ✓ Perses Dashboard, Datasource, and UI Plugin"
log "  ✓ RHACS declarative configuration ConfigMap"
log "  ✓ Prometheus Operator resources (Prometheus, PrometheusRule, secrets)"
log "  ✓ Cluster Observability Operator resources (MonitoringStack, ScrapeConfig)"
log "  ✓ TLS secret for RHACS Prometheus"
log "  ✓ UserPKI auth provider 'Prometheus' from RHACS"
log "  ✓ Cluster Observability Operator (subscription, CSV, namespace)"
log "  ✓ Temporary certificate files"
log ""
log "Note: Some resources may take a few minutes to fully delete."
log "If any resources remain, you may need to remove them manually."
log "========================================================="
log ""
