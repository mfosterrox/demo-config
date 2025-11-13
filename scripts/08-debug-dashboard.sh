#!/bin/bash
# Cluster Observability Operator Dashboard Debugging Script
# Helps troubleshoot why dashboards aren't appearing in OpenShift Console monitoring section

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DEBUG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DEBUG]${NC} $1"
}

error() {
    echo -e "${RED}[DEBUG]${NC} $1"
}

# Configuration
DASHBOARD_NAME="${1:-grafana-dashboard-rhacs-security}"
COO_NAMESPACE="open-cluster-management-observability"
MONITORING_NAMESPACE="openshift-monitoring"

log "Cluster Observability Operator Dashboard Debugging Script"
log "=========================================================="
log "Dashboard: $DASHBOARD_NAME"
log ""

# Check if oc is available
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
    exit 1
fi

# Check if COO is installed
log "Checking for Cluster Observability Operator..."
COO_INSTALLED=false
if oc get namespace $COO_NAMESPACE &>/dev/null 2>&1; then
    if oc get operator cluster-observability-operator -n openshift-operators &>/dev/null 2>&1 || \
       oc get csv -n openshift-operators 2>/dev/null | grep -q "cluster-observability"; then
        COO_INSTALLED=true
        log "✓ Cluster Observability Operator is installed"
    fi
fi

# Determine namespace
DASHBOARD_NAMESPACE=""
if oc get configmap $DASHBOARD_NAME -n $COO_NAMESPACE &>/dev/null 2>&1; then
    DASHBOARD_NAMESPACE="$COO_NAMESPACE"
    log "Found dashboard in COO namespace: $COO_NAMESPACE"
elif oc get configmap $DASHBOARD_NAME -n $MONITORING_NAMESPACE &>/dev/null 2>&1; then
    DASHBOARD_NAMESPACE="$MONITORING_NAMESPACE"
    log "Found dashboard in monitoring namespace: $MONITORING_NAMESPACE"
    if [ "$COO_INSTALLED" = true ]; then
        warning "COO is installed but dashboard is in openshift-monitoring namespace"
        warning "For COO, dashboards should be in: $COO_NAMESPACE"
    fi
else
    error "Dashboard ConfigMap '$DASHBOARD_NAME' not found in either namespace"
    log "Searching all namespaces..."
    oc get configmap $DASHBOARD_NAME -A 2>/dev/null || error "Dashboard not found anywhere"
    exit 1
fi

log "Using namespace: $DASHBOARD_NAMESPACE"
log ""

# 1. Check ConfigMap exists
log "1. Checking ConfigMap..."
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE &>/dev/null; then
    log "✓ ConfigMap exists"
else
    error "✗ ConfigMap not found"
    exit 1
fi

# 2. Check labels (COO requires grafana-custom-dashboard label)
log ""
log "2. Checking ConfigMap labels..."
LABELS=$(oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.labels}' 2>/dev/null)
echo "$LABELS" | python3 -m json.tool 2>/dev/null || echo "$LABELS"
echo ""

if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    if echo "$LABELS" | grep -q "grafana-custom-dashboard"; then
        log "✓ Has required COO label: grafana-custom-dashboard"
    else
        error "✗ Missing required COO label!"
        log "COO requires: grafana-custom-dashboard: \"true\""
        log "Fix with: oc label configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE grafana-custom-dashboard=true"
    fi
else
    if echo "$LABELS" | grep -q "grafana_dashboard"; then
        log "✓ Has Grafana dashboard label"
    else
        warning "✗ Missing Grafana dashboard label!"
        log "Expected: grafana_dashboard: \"1\""
    fi
fi

# 3. Check annotations (COO uses annotations for folder organization)
log ""
log "3. Checking ConfigMap annotations..."
ANNOTATIONS=$(oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.annotations}' 2>/dev/null)
if [ -n "$ANNOTATIONS" ] && [ "$ANNOTATIONS" != "{}" ]; then
    echo "$ANNOTATIONS" | python3 -m json.tool 2>/dev/null || echo "$ANNOTATIONS"
    echo ""
    if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
        if echo "$ANNOTATIONS" | grep -q "observability.open-cluster-management.io/dashboard-folder"; then
            log "✓ Has COO dashboard folder annotation"
        else
            log "ℹ No folder annotation (dashboard will appear in 'General' folder)"
            log "To add folder: oc annotate configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE observability.open-cluster-management.io/dashboard-folder=RHACS"
        fi
    fi
else
    log "No annotations found"
    if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
        log "ℹ Consider adding folder annotation for better organization"
    fi
fi

# 4. Validate JSON
log ""
log "4. Validating dashboard JSON..."
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.data.rhacs-security\.json}' 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
    log "✓ Dashboard JSON is valid"
else
    error "✗ Dashboard JSON is invalid or malformed"
    log "Attempting to show JSON structure..."
    oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.data.rhacs-security\.json}' 2>/dev/null | head -20
fi

# 5. Check COO observability stack (for COO namespace)
if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log ""
    log "5. Checking Cluster Observability Operator components..."
    
    # Check observability stack pods
    log "COO observability stack pods:"
    oc get pods -n $COO_NAMESPACE 2>/dev/null | grep -E "observability|grafana|prometheus" | head -10 || log "No observability pods found"
    
    # Check MultiClusterObservability CR
    log ""
    log "Checking MultiClusterObservability custom resource..."
    if oc get multiclusterobservability -n $COO_NAMESPACE &>/dev/null 2>&1; then
        log "✓ MultiClusterObservability CR found"
        oc get multiclusterobservability -n $COO_NAMESPACE
    else
        warning "✗ MultiClusterObservability CR not found"
        log "COO may not be fully configured"
    fi
    
    # Check Grafana deployment in COO namespace
    if oc get deployment grafana -n $COO_NAMESPACE &>/dev/null 2>&1; then
        log "✓ Grafana deployment found in COO namespace"
        GRAFANA_NS="$COO_NAMESPACE"
        GRAFANA_FOUND=true
    else
        warning "✗ Grafana deployment not found in COO namespace"
        GRAFANA_FOUND=false
    fi
else
    # Standard monitoring checks
    log ""
    log "5. Checking Grafana deployment..."
    GRAFANA_FOUND=false
    if oc get deployment grafana -n openshift-monitoring &>/dev/null 2>&1; then
        log "✓ Grafana deployment found in openshift-monitoring"
        GRAFANA_FOUND=true
        GRAFANA_NS="openshift-monitoring"
    else
        warning "✗ Grafana deployment not found"
    fi
fi

# 6. Check Grafana pods
if [ "$GRAFANA_FOUND" = true ]; then
    log ""
    log "6. Checking Grafana pods..."
    GRAFANA_PODS=$(oc get pods -n $GRAFANA_NS -l app=grafana 2>/dev/null || \
                   oc get pods -n $GRAFANA_NS -l app.kubernetes.io/name=grafana 2>/dev/null || \
                   oc get pods -n $GRAFANA_NS | grep grafana 2>/dev/null)
    if [ -n "$GRAFANA_PODS" ]; then
        echo "$GRAFANA_PODS"
        log "✓ Grafana pods found"
    else
        warning "✗ No Grafana pods found"
    fi
fi

# 7. List all dashboards Grafana should see
log ""
log "7. Listing all dashboards in namespace..."
if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log "Dashboards with grafana-custom-dashboard label:"
    oc get configmap -n $DASHBOARD_NAMESPACE -l grafana-custom-dashboard 2>/dev/null | head -10
else
    log "Dashboards with grafana_dashboard label:"
    oc get configmap -n $DASHBOARD_NAMESPACE -l grafana_dashboard 2>/dev/null | head -10
fi

# 8. Check Grafana logs
if [ "$GRAFANA_FOUND" = true ]; then
    log ""
    log "8. Checking Grafana logs for dashboard-related messages..."
    log "Recent logs (last 50 lines):"
    if oc logs -n $GRAFANA_NS -l app=grafana --tail=50 2>/dev/null | grep -i -E "dashboard|configmap|error" | tail -10; then
        log "Found dashboard-related log entries"
    else
        log "No dashboard-related log entries found (this may be normal)"
    fi
fi

# 9. Check Grafana route
log ""
log "9. Checking Grafana route..."
if oc get route grafana -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
    GRAFANA_ROUTE=$(oc get route grafana -n $DASHBOARD_NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null)
    log "✓ Grafana route: https://$GRAFANA_ROUTE"
elif oc get route grafana -n openshift-monitoring &>/dev/null 2>&1; then
    GRAFANA_ROUTE=$(oc get route grafana -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
    log "✓ Grafana route: https://$GRAFANA_ROUTE"
else
    warning "✗ No Grafana route found"
fi

# 10. Recommendations
log ""
log "========================================================="
log "RECOMMENDATIONS FOR CLUSTER OBSERVABILITY OPERATOR"
log "========================================================="
log ""

if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log "COO Dashboard Discovery Requirements:"
    log "1. ConfigMap must be in: $COO_NAMESPACE namespace"
    log "2. Label required: grafana-custom-dashboard: \"true\""
    log "3. Annotation (optional): observability.open-cluster-management.io/dashboard-folder: \"RHACS\""
    log "4. Valid JSON in data.rhacs-security.json"
    log ""
    log "If dashboard is not appearing in OpenShift Console:"
    log ""
    log "1. Verify ConfigMap is in COO namespace:"
    log "   oc get configmap $DASHBOARD_NAME -n $COO_NAMESPACE"
    log ""
    log "2. Ensure correct label is present:"
    log "   oc label configmap $DASHBOARD_NAME -n $COO_NAMESPACE grafana-custom-dashboard=true --overwrite"
    log ""
    log "3. Add folder annotation (optional but recommended):"
    log "   oc annotate configmap $DASHBOARD_NAME -n $COO_NAMESPACE observability.open-cluster-management.io/dashboard-folder=RHACS --overwrite"
    log ""
    log "4. Restart COO observability stack to force dashboard reload:"
    if [ "$GRAFANA_FOUND" = true ]; then
        log "   oc rollout restart deployment grafana -n $COO_NAMESPACE"
    fi
    log "   oc rollout restart deployment observability-grafana -n $COO_NAMESPACE 2>/dev/null || true"
    log ""
    log "5. Wait 2-3 minutes for COO to discover and sync the dashboard"
    log ""
    log "6. Check OpenShift Console → Observe → Dashboards"
    log "   Navigate to: OpenShift Console → Observe → Dashboards"
    log "   The dashboard should appear in the dropdown list"
    log ""
    log "7. Check COO operator logs for dashboard discovery issues:"
    log "   oc logs -n openshift-operators -l name=cluster-observability-operator --tail=100 | grep -i dashboard"
    log ""
    log "8. Verify MultiClusterObservability CR is ready:"
    log "   oc get multiclusterobservability -n $COO_NAMESPACE"
    log "   oc describe multiclusterobservability -n $COO_NAMESPACE"
else
    log "Standard OpenShift Monitoring Dashboard:"
    log ""
    log "If dashboard is not appearing:"
    log ""
    log "1. Restart Grafana to force dashboard reload:"
    if [ "$GRAFANA_FOUND" = true ]; then
        log "   oc rollout restart deployment grafana -n $GRAFANA_NS"
    fi
    log ""
    log "2. Wait 1-2 minutes after restart for dashboard discovery"
    log ""
    log "3. Check OpenShift Console → Observe → Dashboards"
    log "   The dashboard should appear in the list if properly configured"
    log ""
    log "4. Verify user-workload monitoring is enabled:"
    log "   oc get configmap cluster-monitoring-config -n openshift-monitoring"
fi

log ""
log "========================================================="

