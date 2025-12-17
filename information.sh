#!/bin/bash
# Information Script - Shows deployment status and access information
# Verifies all operators and deployments from install.sh

# Exit immediately on error
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

section() {
    echo ""
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}=========================================================${NC}"
}

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
    exit 1
fi

log "Connected to OpenShift cluster as: $(oc whoami)"
log ""

# ============================================================================
# SECTION 1: Cluster Operators Status
# ============================================================================
section "1. Cluster Operators Status"

log "Checking cluster operators..."
echo ""

# Get all cluster operators
CO_OUTPUT=$(oc get clusteroperators 2>/dev/null || echo "")

if [ -z "$CO_OUTPUT" ]; then
    warning "Could not retrieve cluster operators. Checking permissions..."
    oc auth can-i get clusteroperators || error "Insufficient permissions to check cluster operators"
else
    echo ""
    log "All Cluster Operators:"
    oc get clusteroperators
    echo ""
    
    # Check for Available=True and Degraded=False
    log "Checking operator availability status..."
    AVAILABLE_COUNT=0
    DEGRADED_COUNT=0
    PROGRESSING_COUNT=0
    
    while IFS= read -r line; do
        if [ -z "$line" ] || echo "$line" | grep -q "NAME"; then
            continue
        fi
        
        OP_NAME=$(echo "$line" | awk '{print $1}')
        AVAILABLE=$(oc get clusteroperator "$OP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
        DEGRADED=$(oc get clusteroperator "$OP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
        PROGRESSING=$(oc get clusteroperator "$OP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$AVAILABLE" = "True" ] && [ "$DEGRADED" != "True" ] && [ "$PROGRESSING" != "True" ]; then
            success "  ✓ $OP_NAME: Available=True, Degraded=False, Progressing=False"
            AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
        elif [ "$AVAILABLE" = "True" ] && [ "$PROGRESSING" = "True" ]; then
            warning "  ⚠ $OP_NAME: Available=True but Progressing=True (may still be installing)"
            PROGRESSING_COUNT=$((PROGRESSING_COUNT + 1))
        elif [ "$AVAILABLE" = "True" ] && [ "$DEGRADED" = "True" ]; then
            warning "  ⚠ $OP_NAME: Available=True but Degraded=True"
            DEGRADED_COUNT=$((DEGRADED_COUNT + 1))
        elif [ "$AVAILABLE" = "False" ]; then
            error "  ✗ $OP_NAME: Available=False"
            DEGRADED_COUNT=$((DEGRADED_COUNT + 1))
        else
            warning "  ? $OP_NAME: Available=$AVAILABLE, Degraded=$DEGRADED, Progressing=$PROGRESSING"
        fi
    done <<< "$(oc get clusteroperators --no-headers 2>/dev/null || echo "")"
    
    echo ""
    log "Summary:"
    log "  Available and Healthy: $AVAILABLE_COUNT"
    log "  Progressing (installing): $PROGRESSING_COUNT"
    log "  Degraded or Unavailable: $DEGRADED_COUNT"
    
    # Check for operators specifically installed by install.sh
    echo ""
    log "Checking for operators installed by install.sh:"
    INSTALLED_OPERATORS=()
    
    # Check cert-manager (may appear as cert-manager-operator or cert-manager)
    if oc get clusteroperator cert-manager &>/dev/null || oc get clusteroperator cert-manager-operator &>/dev/null; then
        INSTALLED_OPERATORS+=("cert-manager")
        success "  ✓ cert-manager operator found in cluster operators"
    else
        warning "  ⚠ cert-manager not found in cluster operators (checking namespace deployment below)"
    fi
    
    # Note: RHACS and Compliance operators may not appear as cluster operators
    # They are installed via subscriptions and will be checked in section 2
    log "  Note: RHACS and Compliance operators are checked via namespace deployments (see section 2)"
fi

# ============================================================================
# SECTION 2: Operator-Specific Checks
# ============================================================================
section "2. Operator-Specific Deployment Checks"

# 2.1 Cert-Manager Operator
log "2.1 Cert-Manager Operator"
CERT_MGR_NS="cert-manager-operator"
if oc get namespace "$CERT_MGR_NS" &>/dev/null; then
    success "  Namespace exists: $CERT_MGR_NS"
    
    # Check CSV
    CSV=$(oc get csv -n "$CERT_MGR_NS" -o name 2>/dev/null | grep cert-manager | head -1 || echo "")
    if [ -n "$CSV" ]; then
        CSV_NAME=$(echo "$CSV" | sed 's|clusterserviceversion.operators.coreos.com/||')
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$CERT_MGR_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        else
            warning "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        fi
    fi
    
    # Check CertManager CR
    if oc get certmanager cluster &>/dev/null; then
        success "  CertManager CR exists"
    else
        warning "  CertManager CR not found"
    fi
    
    # Check pods
    POD_COUNT=$(oc get pods -n "$CERT_MGR_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    RUNNING_COUNT=$(oc get pods -n "$CERT_MGR_NS" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$RUNNING_COUNT" -gt 0 ]; then
        success "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    else
        warning "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    fi
else
    warning "  Namespace not found: $CERT_MGR_NS"
fi
echo ""

# 2.2 RHACS Operator
log "2.2 RHACS Operator"
RHACS_NS="rhacs-operator"
if oc get namespace "$RHACS_NS" &>/dev/null; then
    success "  Namespace exists: $RHACS_NS"
    
    # Check CSV
    CSV=$(oc get csv -n "$RHACS_NS" -o name 2>/dev/null | grep rhacs-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        CSV_NAME=$(echo "$CSV" | sed 's|clusterserviceversion.operators.coreos.com/||')
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$RHACS_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        else
            warning "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        fi
    fi
    
    # Check Central
    if oc get central -n "$RHACS_NS" &>/dev/null; then
        CENTRAL_NAME=$(oc get central -n "$RHACS_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        CENTRAL_STATUS=$(oc get central "$CENTRAL_NAME" -n "$RHACS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$CENTRAL_STATUS" = "True" ]; then
            success "  Central Status: Ready ($CENTRAL_NAME)"
        else
            warning "  Central Status: $CENTRAL_STATUS ($CENTRAL_NAME)"
        fi
    else
        warning "  Central resource not found"
    fi
    
    # Check SecuredCluster
    if oc get securedcluster -n "$RHACS_NS" &>/dev/null; then
        SC_NAME=$(oc get securedcluster -n "$RHACS_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        SC_STATUS=$(oc get securedcluster "$SC_NAME" -n "$RHACS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$SC_STATUS" = "True" ]; then
            success "  SecuredCluster Status: Ready ($SC_NAME)"
        else
            warning "  SecuredCluster Status: $SC_STATUS ($SC_NAME)"
        fi
    else
        warning "  SecuredCluster resource not found"
    fi
    
    # Check pods
    POD_COUNT=$(oc get pods -n "$RHACS_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    RUNNING_COUNT=$(oc get pods -n "$RHACS_NS" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$RUNNING_COUNT" -gt 0 ]; then
        success "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
        
        # Check specific components
        if oc get deployment central -n "$RHACS_NS" &>/dev/null; then
            CENTRAL_READY=$(oc get deployment central -n "$RHACS_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "0/0")
            success "    Central: $CENTRAL_READY ready"
        fi
        
        if oc get deployment sensor -n "$RHACS_NS" &>/dev/null; then
            SENSOR_READY=$(oc get deployment sensor -n "$RHACS_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "0/0")
            success "    Sensor: $SENSOR_READY ready"
        fi
        
        if oc get daemonset collector -n "$RHACS_NS" &>/dev/null; then
            COLLECTOR_READY=$(oc get daemonset collector -n "$RHACS_NS" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || echo "0/0")
            success "    Collector: $COLLECTOR_READY ready"
        fi
        
        if oc get deployment admission-control -n "$RHACS_NS" &>/dev/null; then
            AC_READY=$(oc get deployment admission-control -n "$RHACS_NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "0/0")
            success "    Admission Control: $AC_READY ready"
        fi
    else
        warning "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    fi
else
    warning "  Namespace not found: $RHACS_NS"
fi
echo ""

# 2.3 Compliance Operator
log "2.3 Compliance Operator"
COMPLIANCE_NS="openshift-compliance"
if oc get namespace "$COMPLIANCE_NS" &>/dev/null; then
    success "  Namespace exists: $COMPLIANCE_NS"
    
    # Check CSV
    CSV=$(oc get csv -n "$COMPLIANCE_NS" -o name 2>/dev/null | grep compliance-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        CSV_NAME=$(echo "$CSV" | sed 's|clusterserviceversion.operators.coreos.com/||')
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$COMPLIANCE_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        else
            warning "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        fi
    fi
    
    # Check pods
    POD_COUNT=$(oc get pods -n "$COMPLIANCE_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    RUNNING_COUNT=$(oc get pods -n "$COMPLIANCE_NS" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$RUNNING_COUNT" -gt 0 ]; then
        success "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    else
        warning "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    fi
    
    # Check ComplianceScans
    SCAN_COUNT=$(oc get compliancescans -n "$COMPLIANCE_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$SCAN_COUNT" -gt 0 ]; then
        success "  ComplianceScans: $SCAN_COUNT found"
    fi
else
    warning "  Namespace not found: $COMPLIANCE_NS"
fi
echo ""

# 2.4 Cluster Observability Operator
log "2.4 Cluster Observability Operator"
COO_NS="openshift-cluster-observability-operator"
if oc get namespace "$COO_NS" &>/dev/null; then
    success "  Namespace exists: $COO_NS"
    
    # Check CSV
    CSV=$(oc get csv -n "$COO_NS" -o name 2>/dev/null | grep cluster-observability-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        CSV_NAME=$(echo "$CSV" | sed 's|clusterserviceversion.operators.coreos.com/||')
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$COO_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        else
            warning "  CSV Status: $CSV_PHASE ($CSV_NAME)"
        fi
    fi
    
    # Check pods
    POD_COUNT=$(oc get pods -n "$COO_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    RUNNING_COUNT=$(oc get pods -n "$COO_NS" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$RUNNING_COUNT" -gt 0 ]; then
        success "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    else
        warning "  Pods: $RUNNING_COUNT/$POD_COUNT Running"
    fi
    
    # Check MonitoringStack in rhacs-operator namespace
    if oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NS" &>/dev/null; then
        MS_STATUS=$(oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$MS_STATUS" = "True" ]; then
            success "  MonitoringStack: Ready (rhacs-monitoring-stack)"
        else
            warning "  MonitoringStack: $MS_STATUS (rhacs-monitoring-stack)"
        fi
    fi
    
    # Check Prometheus
    if oc get prometheus rhacs-prometheus-server -n "$RHACS_NS" &>/dev/null; then
        PROM_STATUS=$(oc get prometheus rhacs-prometheus-server -n "$RHACS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$PROM_STATUS" = "True" ]; then
            success "  Prometheus: Ready (rhacs-prometheus-server)"
        else
            warning "  Prometheus: $PROM_STATUS (rhacs-prometheus-server)"
        fi
    fi
    
    # Check Perses Datasource
    if oc get datasource rhacs-datasource -n "$RHACS_NS" &>/dev/null; then
        success "  Perses Datasource: Found (rhacs-datasource)"
    fi
else
    warning "  Namespace not found: $COO_NS"
fi
echo ""

# 2.5 Demo Applications (if deployed)
log "2.5 Demo Applications"
# Check for common demo application namespaces
DEMO_NAMESPACES=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -E "(demo|test|sample|tutorial|app)" || echo "")
if [ -n "$DEMO_NAMESPACES" ]; then
    log "  Found potential demo application namespaces:"
    for ns in $DEMO_NAMESPACES; do
        POD_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
        RUNNING_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [ "$POD_COUNT" -gt 0 ]; then
            if [ "$RUNNING_COUNT" -eq "$POD_COUNT" ]; then
                success "    $ns: $RUNNING_COUNT/$POD_COUNT pods Running"
            else
                warning "    $ns: $RUNNING_COUNT/$POD_COUNT pods Running"
            fi
        fi
    done
else
    log "  No demo application namespaces detected"
fi
echo ""

# ============================================================================
# SECTION 3: Access Information
# ============================================================================
section "3. Operator Access Information"

# 3.0 OpenShift Console
log "3.0 OpenShift Console"
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
if [ -n "$CONSOLE_URL" ]; then
    success "  Console URL: $CONSOLE_URL"
    log "    Access the OpenShift web console to manage all operators and resources"
else
    log "  Console URL: (run 'oc whoami --show-console' to get URL)"
fi
echo ""

# 3.1 RHACS Access
log "3.1 RHACS (Red Hat Advanced Cluster Security)"
RHACS_NAMESPACE="rhacs-operator"

CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_ROUTE" ]; then
    success "  Central Route: https://$CENTRAL_ROUTE"
    
    # Get admin password
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASSWORD_B64" ]; then
        ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            success "  Username: admin"
            success "  Password: $ADMIN_PASSWORD"
        else
            warning "  Username: admin"
            warning "  Password: (retrieve with: oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"
        fi
    else
        warning "  Username: admin"
        warning "  Password: (retrieve with: oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"
    fi
    
    log ""
    log "  Access RHACS UI:"
    log "    URL: https://$CENTRAL_ROUTE"
    log "    Username: admin"
    if [ -n "$ADMIN_PASSWORD" ]; then
        log "    Password: $ADMIN_PASSWORD"
    fi
    log ""
    log "  Access RHACS API:"
    log "    Endpoint: https://$CENTRAL_ROUTE"
    log "    Generate API token:"
    log "      curl -k -u admin:\$ADMIN_PASSWORD https://$CENTRAL_ROUTE/v1/apitokens/generate -X POST -H 'Content-Type: application/json' -d '{\"name\":\"my-token\",\"roles\":[\"Admin\"]}'"
    log ""
    log "  Use roxctl CLI:"
    log "    roxctl -e $CENTRAL_ROUTE central <command>"
    log "    Or set: export ROX_ENDPOINT=$CENTRAL_ROUTE"
else
    warning "  Central route not found. Central may still be deploying."
    warning "  Check status: oc get route central -n $RHACS_NAMESPACE"
fi
echo ""

# 3.2 Cert-Manager Access
log "3.2 Cert-Manager"
log "  Cert-Manager is a cluster-scoped operator."
log "  View certificates: oc get certificates --all-namespaces"
log "  View ClusterIssuers: oc get clusterissuers"
log "  View CertManager CR: oc get certmanager cluster"
log ""
log "  Access operator logs:"
log "    oc logs -n cert-manager-operator -l name=cert-manager-operator"
echo ""

# 3.3 Compliance Operator Access
log "3.3 Compliance Operator"
log "  View ComplianceScans: oc get compliancescans -n openshift-compliance"
log "  View ScanSettingBindings: oc get scansettingbindings -n openshift-compliance"
log "  View ComplianceCheckResults: oc get compliancecheckresults -n openshift-compliance"
log ""
log "  Access operator logs:"
log "    oc logs -n openshift-compliance -l name=compliance-operator"
log ""
log "  View compliance results in RHACS:"
log "    Compliance results are automatically synced to RHACS Central"
log "    Access via RHACS UI: https://$CENTRAL_ROUTE (if available)"
echo ""

# 3.4 Cluster Observability Operator / Perses Access
log "3.4 Cluster Observability Operator / Perses Monitoring"
if oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NS" &>/dev/null; then
    log "  MonitoringStack: rhacs-monitoring-stack (namespace: $RHACS_NS)"
    
    # Check for Perses route
    PERSES_ROUTE=$(oc get route -n "$RHACS_NS" -o jsonpath='{.items[?(@.metadata.name=="perses")].spec.host}' 2>/dev/null || echo "")
    if [ -z "$PERSES_ROUTE" ]; then
        # Try alternative route names
        PERSES_ROUTE=$(oc get route -n "$RHACS_NS" -o jsonpath='{.items[?(@.spec.to.name=="perses")].spec.host}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$PERSES_ROUTE" ]; then
        success "  Perses UI: https://$PERSES_ROUTE"
        log "    Access Perses dashboards for RHACS metrics visualization"
        log "    Dashboard: rhacs-dashboard (should be available in Perses UI)"
    else
        log "  Perses route: (check with: oc get routes -n $RHACS_NS)"
        log "    Perses may be accessible via OpenShift console"
        log "    Check: OpenShift Console -> Developer Perspective -> Topology -> $RHACS_NS namespace"
    fi
    
    # Check Prometheus route
    PROM_ROUTE=$(oc get route -n "$RHACS_NS" -o jsonpath='{.items[?(@.metadata.name=="rhacs-prometheus-server")].spec.host}' 2>/dev/null || echo "")
    if [ -z "$PROM_ROUTE" ]; then
        # Try alternative route names
        PROM_ROUTE=$(oc get route -n "$RHACS_NS" -o jsonpath='{.items[?(@.spec.to.name=="prometheus")].spec.host}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$PROM_ROUTE" ]; then
        log "  Prometheus UI: https://$PROM_ROUTE"
        log "    Access Prometheus to query RHACS metrics"
    else
        log "  Prometheus route: (check with: oc get routes -n $RHACS_NS)"
    fi
    
    log ""
    log "  Access Perses via OpenShift Console:"
    log "    1. Open OpenShift Console: $CONSOLE_URL"
    log "    2. Switch to Developer perspective"
    log "    3. Navigate to Topology view"
    log "    4. Select namespace: $RHACS_NS"
    log "    5. Look for Perses service/route"
    log ""
    log "  View monitoring resources:"
    log "    oc get monitoringstack -n $RHACS_NS"
    log "    oc get prometheus -n $RHACS_NS"
    log "    oc get datasource -n $RHACS_NS"
    log "    oc get dashboard -n $RHACS_NS"
    log "    oc get routes -n $RHACS_NS"
else
    warning "  MonitoringStack not found. Monitoring may not be configured."
fi
echo ""

# ============================================================================
# SECTION 4: Quick Reference Commands
# ============================================================================
section "4. Quick Reference Commands"

log "Check operator status:"
log "  oc get clusteroperators"
log "  oc get csv --all-namespaces"
log ""
log "Check RHACS components:"
log "  oc get pods -n rhacs-operator"
log "  oc get central -n rhacs-operator"
log "  oc get securedcluster -n rhacs-operator"
log ""
log "Check Compliance Operator:"
log "  oc get pods -n openshift-compliance"
log "  oc get compliancescans -n openshift-compliance"
log ""
log "Check Cert-Manager:"
log "  oc get pods -n cert-manager-operator"
log "  oc get certmanager cluster"
log "  oc get certificates --all-namespaces"
log ""
log "Check Monitoring:"
log "  oc get monitoringstack -n rhacs-operator"
log "  oc get prometheus -n rhacs-operator"
log "  oc get routes -n rhacs-operator"
log ""
log "View logs:"
log "  oc logs -n rhacs-operator -l app=central"
log "  oc logs -n rhacs-operator -l app=sensor"
log "  oc logs -n openshift-compliance -l name=compliance-operator"
log ""

# ============================================================================
# Summary
# ============================================================================
section "Summary"

log "Deployment verification complete!"
log ""
log "Key components checked:"
log "  ✓ Cluster Operators"
log "  ✓ Cert-Manager Operator"
log "  ✓ RHACS Operator and Components"
log "  ✓ Compliance Operator"
log "  ✓ Cluster Observability Operator / Perses"
log ""
log "For detailed status, review the sections above."
log ""

