#!/bin/bash

# Demo Config - Environment Information Script
# Displays comprehensive information about the installed environment

# Exit immediately on error
set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Section header
section() {
    echo ""
    echo -e "${CYAN}=========================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}=========================================================${NC}"
}

# Info line
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Success line
success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# Warning line
warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Error line
error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if oc is available
if ! command -v oc >/dev/null 2>&1; then
    error "OpenShift CLI (oc) is not installed or not in PATH"
    exit 1
fi

# Check if connected to cluster
if ! oc whoami >/dev/null 2>&1; then
    error "Not connected to OpenShift cluster. Please login first: oc login"
    exit 1
fi

# Script directory not needed for this script (it only queries cluster state)

# Load environment variables from ~/.bashrc if they exist
# Only load specific variables we need, using a safe method
if [ -f ~/.bashrc ]; then
    # Use process substitution to avoid subshell issues
    while IFS= read -r line; do
        # Only eval if line looks safe (starts with export and one of our vars)
        if [[ "$line" =~ ^export\ (RHACS_NAMESPACE|ROX_ENDPOINT|ROX_API_TOKEN|ADMIN_PASSWORD|TUTORIAL_HOME|CONSOLE_ROUTE|RHDH_ROUTE|COMPLIANCE_NAMESPACE|CERT_MANAGER_NAMESPACE|COO_NAMESPACE)= ]]; then
            eval "$line" 2>/dev/null || true
        fi
    done < <(grep -E "^export (RHACS_NAMESPACE|ROX_ENDPOINT|ROX_API_TOKEN|ADMIN_PASSWORD|TUTORIAL_HOME|CONSOLE_ROUTE|RHDH_ROUTE|COMPLIANCE_NAMESPACE|CERT_MANAGER_NAMESPACE|COO_NAMESPACE)=" ~/.bashrc 2>/dev/null || true)
fi

# Default namespaces
RHACS_NAMESPACE="${RHACS_NAMESPACE:-rhacs-operator}"
COMPLIANCE_NAMESPACE="${COMPLIANCE_NAMESPACE:-openshift-compliance}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager-operator}"
COO_NAMESPACE="${COO_NAMESPACE:-openshift-cluster-observability-operator}"

echo ""
section "Demo Config - Environment Information"
echo ""
info "Generated: $(date)"
echo ""

# ============================================================
# OpenShift Cluster Information
# ============================================================
section "OpenShift Cluster Information"

CLUSTER_USER=$(oc whoami 2>/dev/null || echo "unknown")
info "Current User: $CLUSTER_USER"

CLUSTER_URL=$(oc whoami --show-server 2>/dev/null || echo "unknown")
info "Cluster URL: $CLUSTER_URL"

CLUSTER_VERSION=$(oc version -o json 2>/dev/null | grep -o '"openshiftVersion":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
if [ "$CLUSTER_VERSION" != "unknown" ]; then
    info "OpenShift Version: $CLUSTER_VERSION"
fi

KUBERNETES_VERSION=$(oc version -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
if [ "$KUBERNETES_VERSION" != "unknown" ]; then
    info "Kubernetes Version: $KUBERNETES_VERSION"
fi

# Check cluster admin privileges
if oc auth can-i create subscriptions --all-namespaces >/dev/null 2>&1; then
    success "Cluster admin privileges: Yes"
else
    warning "Cluster admin privileges: No (limited information may be displayed)"
fi

# ============================================================
# RHACS Information
# ============================================================
section "RHACS (Red Hat Advanced Cluster Security) Information"

# Check namespace
if oc get namespace "$RHACS_NAMESPACE" >/dev/null 2>&1; then
    success "Namespace '$RHACS_NAMESPACE' exists"
    
    # ============================================================
    # Gather all information first (all checks done here)
    # ============================================================
    
    # Get Central route
    CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    # Get admin password
    ADMIN_PASSWORD=""
    if [ -n "$CENTRAL_ROUTE" ]; then
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        fi
    fi
    
    # Get ROX_ENDPOINT
    ROX_ENDPOINT="${ROX_ENDPOINT:-$CENTRAL_ROUTE}"
    
    # Check Central deployment
    CENTRAL_EXISTS=false
    CENTRAL_READY="unknown"
    CENTRAL_AVAILABLE="unknown"
    if oc get deployment central -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        CENTRAL_EXISTS=true
        CENTRAL_READY=$(oc get deployment central -n "$RHACS_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "unknown")
        CENTRAL_AVAILABLE=$(oc get deployment central -n "$RHACS_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
    fi
    
    # Check Sensor deployment
    SENSOR_EXISTS=false
    SENSOR_READY="unknown"
    if oc get deployment sensor -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        SENSOR_EXISTS=true
        SENSOR_READY=$(oc get deployment sensor -n "$RHACS_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "unknown")
    fi
    
    # Check Admission Control deployment
    ADMISSION_EXISTS=false
    ADMISSION_READY="unknown"
    if oc get deployment admission-control -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        ADMISSION_EXISTS=true
        ADMISSION_READY=$(oc get deployment admission-control -n "$RHACS_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "unknown")
    fi
    
    # Check Collector DaemonSet
    COLLECTOR_EXISTS=false
    COLLECTOR_READY="unknown"
    if oc get daemonset collector -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        COLLECTOR_EXISTS=true
        COLLECTOR_READY=$(oc get daemonset collector -n "$RHACS_NAMESPACE" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || echo "unknown")
    fi
    
    # Check Scanner deployment
    SCANNER_EXISTS=false
    SCANNER_READY="unknown"
    if oc get deployment scanner -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        SCANNER_EXISTS=true
        SCANNER_READY=$(oc get deployment scanner -n "$RHACS_NAMESPACE" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "unknown")
    fi
    
    # Check SecuredCluster resource
    SECUREDCLUSTER_EXISTS=false
    SECUREDCLUSTER_COUNT=0
    SECUREDCLUSTER_LIST=""
    if oc get securedcluster -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        SECUREDCLUSTER_COUNT=$(oc get securedcluster -n "$RHACS_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$SECUREDCLUSTER_COUNT" -gt 0 ]; then
            SECUREDCLUSTER_EXISTS=true
            SECUREDCLUSTER_LIST=$(oc get securedcluster -n "$RHACS_NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].type --no-headers 2>/dev/null || echo "")
        fi
    fi
    
    # ============================================================
    # Display all information (after all checks are complete)
    # ============================================================
    
    # Display Central route and credentials
    if [ -n "$CENTRAL_ROUTE" ]; then
        info "Central Route: $CENTRAL_ROUTE"
        info "RHACS UI URL: https://$CENTRAL_ROUTE"
        if [ -n "$ADMIN_PASSWORD" ]; then
            info "Username: admin"
            info "Password: $ADMIN_PASSWORD"
        fi
        if [ -n "${ROX_API_TOKEN:-}" ]; then
            info "API Token: ${ROX_API_TOKEN:0:20}... (from environment)"
        fi
        if [ -n "$ROX_ENDPOINT" ]; then
            info "ROX_ENDPOINT: $ROX_ENDPOINT"
        fi
    else
        warning "Central route not found (may still be deploying)"
    fi
    
    # Display Central deployment status
    echo ""
    info "Central Deployment Status:"
    if [ "$CENTRAL_EXISTS" = true ]; then
        if [ "$CENTRAL_AVAILABLE" = "True" ]; then
            success "  Central: Ready ($CENTRAL_READY)"
        else
            warning "  Central: Not ready ($CENTRAL_READY, Available: $CENTRAL_AVAILABLE)"
        fi
    else
        warning "  Central deployment not found"
    fi
    
    # Display Secured Cluster Services status
    echo ""
    info "Secured Cluster Services Status:"
    
    if [ "$SENSOR_EXISTS" = true ]; then
        success "  Sensor: Ready ($SENSOR_READY)"
    else
        warning "  Sensor: Not found"
    fi
    
    if [ "$ADMISSION_EXISTS" = true ]; then
        success "  Admission Control: Ready ($ADMISSION_READY)"
    else
        warning "  Admission Control: Not found"
    fi
    
    if [ "$COLLECTOR_EXISTS" = true ]; then
        success "  Collector: Ready ($COLLECTOR_READY)"
    else
        warning "  Collector: Not found"
    fi
    
    if [ "$SCANNER_EXISTS" = true ]; then
        success "  Scanner: Ready ($SCANNER_READY)"
    else
        warning "  Scanner: Not found"
    fi
    
    # Display SecuredCluster resource
    echo ""
    info "SecuredCluster Resource:"
    if [ "$SECUREDCLUSTER_EXISTS" = true ]; then
        success "  Found $SECUREDCLUSTER_COUNT SecuredCluster resource(s)"
        echo "$SECUREDCLUSTER_LIST" | head -5 | sed 's/^/  /'
    else
        warning "  No SecuredCluster resources found"
    fi
    
else
    warning "Namespace '$RHACS_NAMESPACE' not found - RHACS may not be installed"
fi

# ============================================================
# Compliance Operator Information
# ============================================================
section "Compliance Operator Information"

if oc get namespace "$COMPLIANCE_NAMESPACE" >/dev/null 2>&1; then
    success "Namespace '$COMPLIANCE_NAMESPACE' exists"
    
    # Check operator subscription
    echo ""
    info "Operator Status:"
    if oc get subscription compliance-operator -n "$COMPLIANCE_NAMESPACE" >/dev/null 2>&1; then
        CSV_NAME=$(oc get subscription compliance-operator -n "$COMPLIANCE_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$COMPLIANCE_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  Compliance Operator: Installed ($CSV_NAME)"
        else
            warning "  Compliance Operator: $CSV_PHASE"
        fi
    else
        warning "  Compliance Operator subscription not found"
    fi
    
    # Check ScanSettingBindings
    echo ""
    info "Scan Configurations:"
    SCAN_BINDING_COUNT=$(oc get scansettingbinding -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$SCAN_BINDING_COUNT" -gt 0 ]; then
        success "  Found $SCAN_BINDING_COUNT ScanSettingBinding(s)"
        oc get scansettingbinding -n "$COMPLIANCE_NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].type 2>/dev/null | head -10 || true
    else
        warning "  No ScanSettingBindings found"
    fi
    
    # Check ComplianceScans
    echo ""
    info "Compliance Scans:"
    SCAN_COUNT=$(oc get compliancescan -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$SCAN_COUNT" -gt 0 ]; then
        info "  Total Scans: $SCAN_COUNT"
        oc get compliancescan -n "$COMPLIANCE_NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null | head -10 || true
    else
        warning "  No ComplianceScans found"
    fi
    
else
    warning "Namespace '$COMPLIANCE_NAMESPACE' not found - Compliance Operator may not be installed"
fi

# ============================================================
# Perses / Monitoring Information
# ============================================================
section "Perses / Monitoring Information"

# Check Cluster Observability Operator
if oc get namespace "$COO_NAMESPACE" >/dev/null 2>&1; then
    success "Namespace '$COO_NAMESPACE' exists"
    
    echo ""
    info "Cluster Observability Operator Status:"
    if oc get subscription cluster-observability-operator -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        CSV_NAME=$(oc get subscription cluster-observability-operator -n "$COO_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$COO_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            success "  Cluster Observability Operator: Installed ($CSV_NAME)"
        else
            warning "  Cluster Observability Operator: $CSV_PHASE"
        fi
    else
        warning "  Cluster Observability Operator subscription not found"
    fi
    
    # Check MonitoringStack (in COO namespace)
    echo ""
    info "Monitoring Resources:"
    # Check both namespaces in case resources are in different locations
    MONITORINGSTACK_FOUND=false
    MONITORINGSTACK_NS=""
    if oc get monitoringstack rhacs-monitoring-stack -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        MONITORINGSTACK_FOUND=true
        MONITORINGSTACK_NS="$COO_NAMESPACE"
    elif oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        MONITORINGSTACK_FOUND=true
        MONITORINGSTACK_NS="$RHACS_NAMESPACE"
    fi
    
    if [ "$MONITORINGSTACK_FOUND" = true ]; then
        success "  MonitoringStack (rhacs-monitoring-stack): Found in namespace '$MONITORINGSTACK_NS'"
    else
        warning "  MonitoringStack (rhacs-monitoring-stack): Not found"
    fi
    
    SCRAPECONFIG_FOUND=false
    SCRAPECONFIG_NS=""
    if oc get scrapeconfig rhacs-scrape-config -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        SCRAPECONFIG_FOUND=true
        SCRAPECONFIG_NS="$COO_NAMESPACE"
    elif oc get scrapeconfig rhacs-scrape-config -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        SCRAPECONFIG_FOUND=true
        SCRAPECONFIG_NS="$RHACS_NAMESPACE"
    fi
    
    if [ "$SCRAPECONFIG_FOUND" = true ]; then
        success "  ScrapeConfig (rhacs-scrape-config): Found in namespace '$SCRAPECONFIG_NS'"
    else
        warning "  ScrapeConfig (rhacs-scrape-config): Not found"
    fi
    
    PROMETHEUS_FOUND=false
    PROMETHEUS_NS=""
    PROM_STATUS="unknown"
    if oc get prometheus rhacs-prometheus-server -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        PROMETHEUS_FOUND=true
        PROMETHEUS_NS="$COO_NAMESPACE"
        PROM_STATUS=$(oc get prometheus rhacs-prometheus-server -n "$COO_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
    elif oc get prometheus rhacs-prometheus-server -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        PROMETHEUS_FOUND=true
        PROMETHEUS_NS="$RHACS_NAMESPACE"
        PROM_STATUS=$(oc get prometheus rhacs-prometheus-server -n "$RHACS_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
    fi
    
    if [ "$PROMETHEUS_FOUND" = true ]; then
        if [ "$PROM_STATUS" = "True" ]; then
            success "  Prometheus (rhacs-prometheus-server): Available in namespace '$PROMETHEUS_NS'"
        else
            warning "  Prometheus (rhacs-prometheus-server): $PROM_STATUS in namespace '$PROMETHEUS_NS'"
        fi
    else
        warning "  Prometheus (rhacs-prometheus-server): Not found"
    fi
    
    # Check Perses resources (check both namespaces)
    echo ""
    info "Perses Resources:"
    DATASOURCE_FOUND=false
    DATASOURCE_NS=""
    if oc get datasource rhacs-datasource -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        DATASOURCE_FOUND=true
        DATASOURCE_NS="$COO_NAMESPACE"
    elif oc get datasource rhacs-datasource -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        DATASOURCE_FOUND=true
        DATASOURCE_NS="$RHACS_NAMESPACE"
    fi
    
    if [ "$DATASOURCE_FOUND" = true ]; then
        success "  Datasource (rhacs-datasource): Found in namespace '$DATASOURCE_NS'"
    else
        warning "  Datasource (rhacs-datasource): Not found"
    fi
    
    DASHBOARD_FOUND=false
    DASHBOARD_NS=""
    if oc get dashboard rhacs-dashboard -n "$COO_NAMESPACE" >/dev/null 2>&1; then
        DASHBOARD_FOUND=true
        DASHBOARD_NS="$COO_NAMESPACE"
    elif oc get dashboard rhacs-dashboard -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
        DASHBOARD_FOUND=true
        DASHBOARD_NS="$RHACS_NAMESPACE"
    fi
    
    if [ "$DASHBOARD_FOUND" = true ]; then
        success "  Dashboard (rhacs-dashboard): Found in namespace '$DASHBOARD_NS'"
    else
        warning "  Dashboard (rhacs-dashboard): Not found"
    fi
    
    # UI Plugin is cluster-scoped
    if oc get uiplugin rhacs-ui-plugin >/dev/null 2>&1; then
        success "  UI Plugin (rhacs-ui-plugin): Found (cluster-scoped)"
    else
        warning "  UI Plugin (rhacs-ui-plugin): Not found"
    fi
    
else
    warning "Namespace '$COO_NAMESPACE' not found - Cluster Observability Operator may not be installed"
fi

# ============================================================
# Demo Applications Information
# ============================================================
section "Demo Applications Information"

# Look for namespaces with demo label
DEMO_NAMESPACES=$(oc get namespaces -l demo=roadshow --no-headers -o name 2>/dev/null | sed 's|namespace/||' || echo "")

if [ -n "$DEMO_NAMESPACES" ]; then
    info "Demo Application Namespaces:"
    for ns in $DEMO_NAMESPACES; do
        echo "  - $ns"
        POD_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        RUNNING_COUNT=$(oc get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$POD_COUNT" -gt 0 ]; then
            info "    Pods: $POD_COUNT (Running: $RUNNING_COUNT)"
        fi
    done
else
    info "No demo application namespaces found (label: demo=roadshow)"
fi

# Check for TUTORIAL_HOME environment variable
if [ -n "${TUTORIAL_HOME:-}" ]; then
    echo ""
    info "Tutorial Home Directory: $TUTORIAL_HOME"
    if [ -d "$TUTORIAL_HOME" ]; then
        success "  Directory exists"
    else
        warning "  Directory does not exist"
    fi
fi

# ============================================================
# Environment Variables
# ============================================================
section "Environment Variables"

# Check for saved environment variables in ~/.bashrc
if [ -f ~/.bashrc ]; then
    info "Saved Environment Variables (from ~/.bashrc):"
    
    # Extract exported variables with comments
    ENV_VARS=$(grep -E "^export (RHACS_NAMESPACE|ROX_ENDPOINT|ROX_API_TOKEN|ADMIN_PASSWORD|TUTORIAL_HOME|CONSOLE_ROUTE|RHDH_ROUTE)=" ~/.bashrc 2>/dev/null || echo "")
    
    if [ -n "$ENV_VARS" ]; then
        # Get comments before each export
        while IFS= read -r line; do
            VAR_NAME=$(echo "$line" | sed -n 's/^export \([^=]*\)=.*/\1/p')
            VAR_VALUE=$(echo "$line" | sed -n "s/^export ${VAR_NAME}='\(.*\)'/\1/p" | sed "s/'/'/g")
            
            # Get comment if exists (line before export)
            LINE_NUM=$(grep -n "^export ${VAR_NAME}=" ~/.bashrc 2>/dev/null | cut -d: -f1)
            if [ -n "$LINE_NUM" ] && [ "$LINE_NUM" -gt 1 ]; then
                COMMENT=$(sed -n "$((LINE_NUM-1))p" ~/.bashrc 2>/dev/null | sed 's/^# //' || echo "")
            fi
            
            if [ -n "$VAR_NAME" ]; then
                if [ "$VAR_NAME" = "ROX_API_TOKEN" ] && [ -n "$VAR_VALUE" ]; then
                    info "  $VAR_NAME: ${VAR_VALUE:0:20}... (${#VAR_VALUE} chars)"
                elif [ "$VAR_NAME" = "ADMIN_PASSWORD" ] && [ -n "$VAR_VALUE" ]; then
                    info "  $VAR_NAME: $VAR_VALUE"
                else
                    info "  $VAR_NAME: ${VAR_VALUE:-not set}"
                fi
                if [ -n "$COMMENT" ]; then
                    info "    ($COMMENT)"
                fi
            fi
        done <<< "$ENV_VARS"
    else
        info "  No saved environment variables found"
    fi
else
    info "~/.bashrc not found - no saved environment variables"
fi

# ============================================================
# Quick Access Commands
# ============================================================
section "Quick Access Commands"

if [ -n "${CENTRAL_ROUTE:-}" ]; then
    info "RHACS UI:"
    echo "  https://$CENTRAL_ROUTE"
    echo ""
fi

info "Useful Commands:"
echo "  # View RHACS pods:"
echo "  oc get pods -n $RHACS_NAMESPACE"
echo ""
echo "  # View Compliance scans:"
echo "  oc get compliancescan -n $COMPLIANCE_NAMESPACE"
echo ""
echo "  # View SecuredCluster status:"
echo "  oc get securedcluster -n $RHACS_NAMESPACE"
echo ""
echo "  # Get RHACS admin password:"
echo "  oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
echo ""

# ============================================================
# Summary
# ============================================================
section "Summary"

COMPONENTS_INSTALLED=0
COMPONENTS_TOTAL=4

# Check RHACS
if oc get namespace "$RHACS_NAMESPACE" >/dev/null 2>&1 && oc get route central -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
    COMPONENTS_INSTALLED=$((COMPONENTS_INSTALLED + 1))
fi

# Check Compliance Operator
if oc get namespace "$COMPLIANCE_NAMESPACE" >/dev/null 2>&1 && oc get subscription compliance-operator -n "$COMPLIANCE_NAMESPACE" >/dev/null 2>&1; then
    COMPONENTS_INSTALLED=$((COMPONENTS_INSTALLED + 1))
fi

# Check Cluster Observability Operator
if oc get namespace "$COO_NAMESPACE" >/dev/null 2>&1 && oc get subscription cluster-observability-operator -n "$COO_NAMESPACE" >/dev/null 2>&1; then
    COMPONENTS_INSTALLED=$((COMPONENTS_INSTALLED + 1))
fi

# Check MonitoringStack (check COO namespace first, then RHACS namespace)
if oc get monitoringstack rhacs-monitoring-stack -n "$COO_NAMESPACE" >/dev/null 2>&1 || oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
    COMPONENTS_INSTALLED=$((COMPONENTS_INSTALLED + 1))
fi

info "Components Installed: $COMPONENTS_INSTALLED/$COMPONENTS_TOTAL"

if [ "$COMPONENTS_INSTALLED" -eq "$COMPONENTS_TOTAL" ]; then
    success "All components are installed!"
elif [ "$COMPONENTS_INSTALLED" -gt 0 ]; then
    warning "Some components may still be installing or missing"
else
    error "No components found - installation may be required"
fi

echo ""
info "For more information, run: ./install.sh"
echo ""

