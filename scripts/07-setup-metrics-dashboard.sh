#!/bin/bash
# Setup Metrics Dashboard Script
# Sets up Cluster Observability Operator to expose RHACS metrics to OpenShift monitoring console
# Based on: https://github.com/stackrox/monitoring-examples/tree/main/cluster-observability-operator

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[METRICS-DASHBOARD]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[METRICS-DASHBOARD]${NC} $1"
}

error() {
    echo -e "${RED}[METRICS-DASHBOARD] ERROR:${NC} $1" >&2
    echo -e "${RED}[METRICS-DASHBOARD] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Source environment variables
if [ -f ~/.bashrc ]; then
    log "Sourcing ~/.bashrc..."
    
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    set +u  # Temporarily disable unbound variable checking
    if ! source ~/.bashrc; then
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    log "~/.bashrc not found, proceeding with current environment"
fi

# Validate required environment variables
if [ -z "${ROX_ENDPOINT:-}" ]; then
    error "ROX_ENDPOINT is not set. Please run script 01-rhacs-setup.sh first."
fi

# Get namespace from environment or default
NAMESPACE="${NAMESPACE:-tssc-acs}"

log "========================================================="
log "Setting up Cluster Observability Operator for RHACS"
log "========================================================="
log "Namespace: $NAMESPACE"
log "RHACS Endpoint: $ROX_ENDPOINT"

# Verify we're connected to OpenShift cluster
if ! command -v oc &>/dev/null; then
    error "OpenShift CLI (oc) is not installed or not in PATH"
fi

if ! oc whoami &>/dev/null; then
    error "Not logged into OpenShift cluster. Please run 'oc login' first."
fi

log "✓ Connected to OpenShift cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"

# Check if RHACS Central is deployed
log "Verifying RHACS Central deployment..."
if ! oc get deployment central -n "$NAMESPACE" &>/dev/null; then
    error "RHACS Central deployment not found in namespace $NAMESPACE"
fi

log "✓ RHACS Central deployment found"

# Check if Central service exists
log "Checking for Central service..."
if ! oc get service central -n "$NAMESPACE" &>/dev/null; then
    error "Central service not found in namespace $NAMESPACE"
fi

log "✓ Central service found"

# Check if Cluster Observability Operator is installed
log "Checking for Cluster Observability Operator..."
OBSERVABILITY_OPERATOR_NAMESPACE="openshift-cluster-observability-operator"
OBSERVABILITY_OPERATOR_INSTALLED=false

# Check if the operator CRD exists and is established (primary API group)
if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
    CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.rhobs -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
    if [ "$CRD_CONDITION" = "True" ]; then
        log "✓ Cluster Observability Operator CRD found and established (monitoring.rhobs)"
        OBSERVABILITY_OPERATOR_INSTALLED=true
        CRD_API_GROUP="monitoring.rhobs"
    else
        log "Cluster Observability Operator CRD exists but not yet established (monitoring.rhobs)"
    fi
elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
    CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.observability.openshift.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
    if [ "$CRD_CONDITION" = "True" ]; then
        log "✓ Cluster Observability Operator CRD found and established (monitoring.observability.openshift.io)"
        OBSERVABILITY_OPERATOR_INSTALLED=true
        CRD_API_GROUP="monitoring.observability.openshift.io"
    else
        log "Cluster Observability Operator CRD exists but not yet established (monitoring.observability.openshift.io)"
    fi
fi

# Check if operator subscription exists
# Use explicit API group to avoid ambiguity with other subscription types
if oc get subscription.operators.coreos.com cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
    log "✓ Cluster Observability Operator subscription found"
    OBSERVABILITY_OPERATOR_INSTALLED=true
fi

# Install Cluster Observability Operator if not installed
if [ "$OBSERVABILITY_OPERATOR_INSTALLED" = false ]; then
    log "Installing Cluster Observability Operator..."
    log "This will install the operator via OperatorHub (OLM)"
    
    # Create namespace if it doesn't exist
    if ! oc get namespace "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "Creating namespace: $OBSERVABILITY_OPERATOR_NAMESPACE"
        oc create namespace "$OBSERVABILITY_OPERATOR_NAMESPACE" || error "Failed to create namespace $OBSERVABILITY_OPERATOR_NAMESPACE"
        log "✓ Namespace created"
    else
        log "✓ Namespace already exists: $OBSERVABILITY_OPERATOR_NAMESPACE"
    fi
    
    # Create OperatorGroup if it doesn't exist
    # For cluster-wide installation, use AllNamespaces install mode
    if ! oc get operatorgroup -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "Creating OperatorGroup for cluster-wide installation..."
        OPERATORGROUP_YAML=$(cat <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator-group
  namespace: $OBSERVABILITY_OPERATOR_NAMESPACE
spec: {}
EOF
        )
        echo "$OPERATORGROUP_YAML" | oc create -f - || error "Failed to create OperatorGroup"
        log "✓ OperatorGroup created (cluster-wide)"
    else
        log "✓ OperatorGroup already exists"
    fi
    
    # Create Subscription
    log "Creating Subscription for Cluster Observability Operator..."
    log "Channel: stable, Source: redhat-operators"
    SUBSCRIPTION_YAML=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: $OBSERVABILITY_OPERATOR_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    )
    
    echo "$SUBSCRIPTION_YAML" | oc create -f - || error "Failed to create Subscription"
    log "✓ Subscription created"
    
    # Wait for CSV to be installed
    log "Waiting for Cluster Observability Operator CSV to be installed..."
    log "This may take 2-5 minutes..."
    CSV_TIMEOUT=600
    CSV_WAIT_INTERVAL=10
    CSV_ELAPSED=0
    CSV_INSTALLED=false
    
    while [ $CSV_ELAPSED -lt $CSV_TIMEOUT ]; do
        # Check for CSV in the namespace
        CSV_NAME=$(oc get csv -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o name 2>/dev/null | grep cluster-observability-operator | head -1 || echo "")
        if [ -n "$CSV_NAME" ]; then
            CSV_STATUS=$(oc get "$CSV_NAME" -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$CSV_STATUS" = "Succeeded" ]; then
                CSV_INSTALLED=true
                log "✓ Cluster Observability Operator CSV installed successfully (Succeeded)"
                break
            elif [ "$CSV_STATUS" = "Failed" ]; then
                error "CSV installation failed. Check: oc get $CSV_NAME -n $OBSERVABILITY_OPERATOR_NAMESPACE"
            else
                log "CSV status: $CSV_STATUS (waiting... ${CSV_ELAPSED}s/${CSV_TIMEOUT}s)"
            fi
        else
            log "Waiting for CSV to appear... (${CSV_ELAPSED}s/${CSV_TIMEOUT}s)"
        fi
        sleep $CSV_WAIT_INTERVAL
        CSV_ELAPSED=$((CSV_ELAPSED + CSV_WAIT_INTERVAL))
    done
    
    if [ "$CSV_INSTALLED" = false ]; then
        warning "CSV installation timeout. Checking status..."
        oc get csv -n "$OBSERVABILITY_OPERATOR_NAMESPACE" || true
        oc get subscription.operators.coreos.com cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o yaml | grep -A 10 "status:" || true
        error "Cluster Observability Operator CSV did not install successfully within timeout"
    fi
    
    # Wait for operator deployment to be ready
    log "Waiting for Cluster Observability Operator deployment to be ready..."
    DEPLOYMENT_TIMEOUT=300
    if oc wait --for=condition=Available deployment/cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" --timeout=${DEPLOYMENT_TIMEOUT}s 2>/dev/null; then
        log "✓ Cluster Observability Operator deployment is ready"
    else
        warning "Operator deployment may still be starting. Checking status..."
        oc get deployment cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" || true
        oc get pods -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -l app=cluster-observability-operator || true
        warning "Proceeding anyway - operator may still be initializing..."
    fi
    
    # Wait for CRDs to be registered and established
    log "Waiting for CRDs to be registered and established..."
    CRD_WAIT_TIMEOUT=120
    CRD_WAIT_ELAPSED=0
    CRD_ESTABLISHED=false
    
    while [ $CRD_WAIT_ELAPSED -lt $CRD_WAIT_TIMEOUT ]; do
        # Check if CRD exists and is established
        if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
            CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.rhobs -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
            if [ "$CRD_CONDITION" = "True" ]; then
                CRD_ESTABLISHED=true
                CRD_API_GROUP="monitoring.rhobs"
                log "✓ CRD monitoringstacks.monitoring.rhobs is established"
                break
            fi
        elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
            CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.observability.openshift.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
            if [ "$CRD_CONDITION" = "True" ]; then
                CRD_ESTABLISHED=true
                CRD_API_GROUP="monitoring.observability.openshift.io"
                log "✓ CRD monitoringstacks.monitoring.observability.openshift.io is established"
                break
            fi
        fi
        
        if [ "$CRD_ESTABLISHED" = false ]; then
            sleep 5
            CRD_WAIT_ELAPSED=$((CRD_WAIT_ELAPSED + 5))
            if [ $((CRD_WAIT_ELAPSED % 15)) -eq 0 ]; then
                log "Waiting for CRDs to be established... (${CRD_WAIT_ELAPSED}s/${CRD_WAIT_TIMEOUT}s)"
            fi
        fi
    done
    
    if [ "$CRD_ESTABLISHED" = false ]; then
        # Fallback: check if CRD exists even if not established
        if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
            CRD_API_GROUP="monitoring.rhobs"
            warning "CRD exists but may not be fully established yet. Proceeding anyway..."
        elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
            CRD_API_GROUP="monitoring.observability.openshift.io"
            warning "CRD exists but may not be fully established yet. Proceeding anyway..."
        else
            error "CRDs not available after waiting. Operator may not be fully installed."
        fi
    fi
else
    log "✓ Cluster Observability Operator is already installed"
    
    # Wait for CRDs to be established (not just exist)
    log "Verifying CRDs are established and ready..."
    CRD_WAIT_TIMEOUT=120
    CRD_WAIT_ELAPSED=0
    CRD_ESTABLISHED=false
    
    while [ $CRD_WAIT_ELAPSED -lt $CRD_WAIT_TIMEOUT ]; do
        # Check if CRD exists and is established
        if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
            CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.rhobs -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
            if [ "$CRD_CONDITION" = "True" ]; then
                CRD_ESTABLISHED=true
                CRD_API_GROUP="monitoring.rhobs"
                log "✓ CRD monitoringstacks.monitoring.rhobs is established"
                break
            fi
        elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
            CRD_CONDITION=$(oc get crd monitoringstacks.monitoring.observability.openshift.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "")
            if [ "$CRD_CONDITION" = "True" ]; then
                CRD_ESTABLISHED=true
                CRD_API_GROUP="monitoring.observability.openshift.io"
                log "✓ CRD monitoringstacks.monitoring.observability.openshift.io is established"
                break
            fi
        fi
        
        if [ "$CRD_ESTABLISHED" = false ]; then
            sleep 5
            CRD_WAIT_ELAPSED=$((CRD_WAIT_ELAPSED + 5))
            if [ $((CRD_WAIT_ELAPSED % 15)) -eq 0 ]; then
                log "Waiting for CRDs to be established... (${CRD_WAIT_ELAPSED}s/${CRD_WAIT_TIMEOUT}s)"
            fi
        fi
    done
    
    if [ "$CRD_ESTABLISHED" = false ]; then
        # Fallback: try to determine API group even if not established
        if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
            CRD_API_GROUP="monitoring.rhobs"
            warning "CRD exists but may not be fully established yet"
        elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
            CRD_API_GROUP="monitoring.observability.openshift.io"
            warning "CRD exists but may not be fully established yet"
        else
            error "CRDs not found. Operator may not be fully installed."
        fi
    fi
    
    # Verify operator is running
    if oc get deployment cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "✓ Cluster Observability Operator deployment found"
        if oc wait --for=condition=Available deployment/cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" --timeout=30s 2>/dev/null; then
            log "✓ Cluster Observability Operator is ready"
        else
            warning "Operator deployment may not be ready yet"
        fi
    else
        # Check if operator might be in openshift-operators namespace
        if oc get deployment cluster-observability-operator -n openshift-operators &>/dev/null; then
            log "✓ Cluster Observability Operator deployment found in openshift-operators namespace"
            OBSERVABILITY_OPERATOR_NAMESPACE="openshift-operators"
        else
            warning "Operator deployment not found. Operator may still be installing..."
        fi
    fi
fi

# Create MonitoringStack resource
log "Creating MonitoringStack resource for RHACS metrics..."
log "Using API group: ${CRD_API_GROUP:-monitoring.rhobs}"

# Determine API version based on CRD API group
if [ "${CRD_API_GROUP:-monitoring.rhobs}" = "monitoring.rhobs" ]; then
    MONITORING_STACK_API_VERSION="monitoring.rhobs/v1alpha1"
else
    MONITORING_STACK_API_VERSION="monitoring.observability.openshift.io/v1alpha1"
fi

MONITORING_STACK_YAML=$(cat <<EOF
apiVersion: $MONITORING_STACK_API_VERSION
kind: MonitoringStack
metadata:
  name: rhacs-monitoring-stack
  namespace: $NAMESPACE
  finalizers:
    - monitoring.observability.openshift.io/finalizer
  labels:
    app: monitoring
    component: rhacs-metrics
spec:
  alertmanagerConfig:
    disabled: false
  createClusterRoleBindings: CreateClusterRoleBindings
  logLevel: info
  prometheusConfig:
    replicas: 1
  resourceSelector:
    matchLabels:
      app: central
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi
  retention: 1d
EOF
)

# Create MonitoringStack
log "Creating MonitoringStack 'rhacs-monitoring-stack'..."
if oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
    log "MonitoringStack 'rhacs-monitoring-stack' already exists, updating..."
    echo "$MONITORING_STACK_YAML" | oc apply -f - || error "Failed to update MonitoringStack"
    log "✓ MonitoringStack updated successfully"
else
    log "Creating new MonitoringStack..."
    echo "$MONITORING_STACK_YAML" | oc create -f - || error "Failed to create MonitoringStack"
    log "✓ MonitoringStack created successfully"
fi

# Wait for MonitoringStack to be ready
log "Waiting for MonitoringStack to be ready..."
sleep 10
if oc wait --for=condition=Ready monitoringstack/rhacs-monitoring-stack -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
    log "✓ MonitoringStack is ready"
else
    warning "MonitoringStack may still be initializing. This is normal and may take a few minutes."
fi

# Get Central service details for ScrapeConfig
CENTRAL_SERVICE_NAME="central"
CENTRAL_SERVICE_PORT="443"
CENTRAL_SERVICE_FQDN="${CENTRAL_SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"

log "Central service FQDN: $CENTRAL_SERVICE_FQDN"

# Create ScrapeConfig resource
log "Creating ScrapeConfig resource for RHACS Central metrics..."
log "Using API group: ${CRD_API_GROUP:-monitoring.rhobs}"

# Determine API version for ScrapeConfig (usually same as MonitoringStack)
if [ "${CRD_API_GROUP:-monitoring.rhobs}" = "monitoring.rhobs" ]; then
    SCRAPE_CONFIG_API_VERSION="monitoring.rhobs/v1alpha1"
else
    SCRAPE_CONFIG_API_VERSION="monitoring.observability.openshift.io/v1alpha1"
fi

SCRAPE_CONFIG_YAML=$(cat <<EOF
apiVersion: $SCRAPE_CONFIG_API_VERSION
kind: ScrapeConfig
metadata:
  name: rhacs-central-scrape-config
  namespace: $NAMESPACE
  labels:
    app: central
    component: metrics
spec:
  jobName: rhacs-central-metrics
  scheme: HTTPS
  staticConfigs:
    - targets:
        - "${CENTRAL_SERVICE_FQDN}:${CENTRAL_SERVICE_PORT}"
  tlsConfig:
    insecureSkipVerify: true
EOF
)

# Create ScrapeConfig
log "Creating ScrapeConfig 'rhacs-central-scrape-config'..."
if oc get scrapeconfig rhacs-central-scrape-config -n "$NAMESPACE" &>/dev/null; then
    log "ScrapeConfig 'rhacs-central-scrape-config' already exists, updating..."
    echo "$SCRAPE_CONFIG_YAML" | oc apply -f - || error "Failed to update ScrapeConfig"
    log "✓ ScrapeConfig updated successfully"
else
    log "Creating new ScrapeConfig..."
    echo "$SCRAPE_CONFIG_YAML" | oc create -f - || error "Failed to create ScrapeConfig"
    log "✓ ScrapeConfig created successfully"
fi

# Verify resources were created
log "Verifying resources..."
if oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
    log "✓ MonitoringStack verified"
    oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" -o yaml | grep -A 5 "status:" || true
else
    error "MonitoringStack was not created successfully"
fi

if oc get scrapeconfig rhacs-central-scrape-config -n "$NAMESPACE" &>/dev/null; then
    log "✓ ScrapeConfig verified"
    oc get scrapeconfig rhacs-central-scrape-config -n "$NAMESPACE" -o yaml | grep -A 5 "spec:" || true
else
    error "ScrapeConfig was not created successfully"
fi

# Check Prometheus pods
log "Checking Prometheus pods..."
PROMETHEUS_PODS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus 2>/dev/null | grep -v NAME | wc -l || echo "0")
if [ "$PROMETHEUS_PODS" -gt 0 ]; then
    log "✓ Found $PROMETHEUS_PODS Prometheus pod(s)"
    oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus || true
else
    warning "Prometheus pods not found yet. They may still be starting."
fi

# Check if UIPlugin CRD exists
log "Checking for UIPlugin CRD..."
UIPLUGIN_CRD_AVAILABLE=false
UIPLUGIN_API_VERSION=""

if oc get crd uiplugins.observability.openshift.io &>/dev/null; then
    log "✓ UIPlugin CRD found (observability.openshift.io)"
    UIPLUGIN_CRD_AVAILABLE=true
    UIPLUGIN_API_VERSION="observability.openshift.io/v1alpha1"
elif oc get crd uiplugins.console.openshift.io &>/dev/null; then
    log "✓ UIPlugin CRD found (console.openshift.io)"
    UIPLUGIN_CRD_AVAILABLE=true
    UIPLUGIN_API_VERSION="console.openshift.io/v1"
else
    warning "UIPlugin CRD not found"
    warning "UIPlugin may not be available in all OpenShift versions"
    warning "Skipping UIPlugin creation - dashboards will still be available via Prometheus UI"
fi

# Create UIPlugin resource if CRD is available
if [ "$UIPLUGIN_CRD_AVAILABLE" = true ]; then
    # Get Prometheus service endpoint for UIPlugin
    log "Getting Prometheus service endpoint for UIPlugin configuration..."
    PROMETHEUS_SERVICE="prometheus-operated"
    PROMETHEUS_PORT="9091"
    PROMETHEUS_ENDPOINT="${PROMETHEUS_SERVICE}.${NAMESPACE}.svc.cluster.local:${PROMETHEUS_PORT}"

    # Verify Prometheus service exists
    if oc get service "$PROMETHEUS_SERVICE" -n "$NAMESPACE" &>/dev/null; then
        log "✓ Prometheus service found: $PROMETHEUS_SERVICE"
        # Try to get actual port from service
        ACTUAL_PORT=$(oc get service "$PROMETHEUS_SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "$PROMETHEUS_PORT")
        if [ -n "$ACTUAL_PORT" ] && [ "$ACTUAL_PORT" != "$PROMETHEUS_PORT" ]; then
            PROMETHEUS_PORT="$ACTUAL_PORT"
            PROMETHEUS_ENDPOINT="${PROMETHEUS_SERVICE}.${NAMESPACE}.svc.cluster.local:${PROMETHEUS_PORT}"
            log "Using Prometheus port: $PROMETHEUS_PORT"
        fi
    else
        warning "Prometheus service not found, using default endpoint: $PROMETHEUS_ENDPOINT"
    fi

    log "Prometheus endpoint for datasource: $PROMETHEUS_ENDPOINT"

    # Create all Perses resources at once (batch creation)
    log "Creating all Perses resources (datasource, plugin, dashboard)..."
    
    # Get Prometheus service URL (use HTTP for internal service, port 9090)
    PROMETHEUS_DATASOURCE_URL="http://prometheus-operated.${NAMESPACE}.svc.cluster.local:9090"
    
    # Create PersesDatasource resource
    PERSES_DATASOURCE_YAML=$(cat <<EOF
apiVersion: perses.dev/v1alpha1
kind: PersesDatasource
metadata:
  name: rhacs-datasource
  namespace: $OBSERVABILITY_OPERATOR_NAMESPACE
spec:
  client:
    tls:
      caCert:
        certPath: /ca/service-ca.crt
        type: file
      enable: true
  config:
    default: true
    display:
      name: RHACS Prometheus Datasource
    plugin:
      kind: PrometheusDatasource
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: ${PROMETHEUS_DATASOURCE_URL}
EOF
    )
    
    # Create UIPlugin resource
    UIPLUGIN_YAML=$(cat <<EOF
apiVersion: $UIPLUGIN_API_VERSION
kind: UIPlugin
metadata:
  name: monitoring
  namespace: $OBSERVABILITY_OPERATOR_NAMESPACE
spec:
  monitoring:
    perses:
      enabled: true
  type: Monitoring
EOF
    )
    
    # Create PersesDashboard resource with RHACS dashboard
    
    # Read the dashboard YAML from a here-doc (large dashboard definition)
    PERSES_DASHBOARD_YAML=$(cat <<'DASHBOARD_EOF'
apiVersion: perses.dev/v1alpha1
kind: PersesDashboard
metadata:
  name: rhacs-dashboard
  namespace: openshift-cluster-observability-operator
spec:
  display:
    name: Advanced Cluster Security / Overview
  duration: 30d
  layouts:
    - kind: Grid
      spec:
        display:
          collapse:
            open: true
          title: Policies
        items:
          - content:
              $ref: '#/spec/panels/total_policy_violations'
            height: 3
            width: 6
            x: 0
            y: 0
          - content:
              $ref: '#/spec/panels/total_policies_enabled'
            height: 3
            width: 6
            x: 0
            y: 3
          - content:
              $ref: '#/spec/panels/violations_by_severity'
            height: 6
            width: 6
            x: 6
            y: 0
          - content:
              $ref: '#/spec/panels/violations_over_time_by_severity'
            height: 6
            width: 12
            x: 12
            y: 0
    - kind: Grid
      spec:
        display:
          collapse:
            open: true
          title: Vulnerabilities
        items:
          - content:
              $ref: '#/spec/panels/total_vulnerabilities'
            height: 3
            width: 6
            x: 0
            y: 0
          - content:
              $ref: '#/spec/panels/total_user_fixable_vulnerabilities'
            height: 3
            width: 6
            x: 0
            y: 3
          - content:
              $ref: '#/spec/panels/vulnerabilities_by_severity'
            height: 6
            width: 6
            x: 6
            y: 0
          - content:
              $ref: '#/spec/panels/vulnerabilities_by_asset_over_time'
            height: 6
            width: 12
            x: 12
            y: 0
          - content:
              $ref: '#/spec/panels/fixable_user_workload_vulnerabilities_over_time'
            height: 12
            width: 12
            x: 0
            y: 6
    - kind: Grid
      spec:
        display:
          title: Cluster health
        items:
          - content:
              $ref: '#/spec/panels/cluster_health'
            height: 6
            width: 12
            x: 0
            y: 0
          - content:
              $ref: '#/spec/panels/cert_expiry'
            height: 6
            width: 12
            x: 12
            y: 0
  panels:
    total_policy_violations:
      kind: Panel
      spec:
        display:
          name: Total policy violations
        plugin:
          kind: StatChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_policy_violation_namespace_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace''})'
    vulnerabilities_by_severity:
      kind: Panel
      spec:
        display:
          name: Vulnerabilities by severity
        plugin:
          kind: BarChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (Severity)(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace''})'
                  seriesNameFormat: '{{Severity}}'
    cluster_health:
      kind: Panel
      spec:
        display:
          name: Cluster status
        plugin:
          kind: Table
          spec:
            columnSettings:
              - name: Cluster
              - enableSorting: true
                name: Status
              - enableSorting: true
                name: Upgradability
              - header: timestamp
                hide: true
                name: timestamp
              - header: value
                hide: true
                name: value
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: |
                    group by (Cluster,Status,Upgradability)
                    (rox_central_health_cluster_info{Cluster=~'$Cluster'})
    vulnerabilities_by_asset_over_time:
      kind: Panel
      spec:
        display:
          name: Vulnerabilities by asset over time
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              mode: list
              position: bottom
              values: []
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace'',IsPlatformWorkload=''false''})'
                  seriesNameFormat: User Image vulnerabilities
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace'',IsPlatformWorkload=''true''})'
                  seriesNameFormat: Platform Image vulnerabilities
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_node_vuln_node_severity{Cluster=~''$Cluster''})'
                  seriesNameFormat: Node vulnerabilities
    violations_over_time_by_severity:
      kind: Panel
      spec:
        display:
          name: Policy violations over time by severity
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (Severity)(rox_central_policy_violation_namespace_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace''})'
                  seriesNameFormat: '{{Severity}}'
    total_policies_enabled:
      kind: Panel
      spec:
        display:
          name: Total policies enabled
        plugin:
          kind: StatChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_cfg_total_policies{Enabled=''true''})'
    cert_expiry:
      kind: Panel
      spec:
        display:
          name: Certificate expiry per component
        plugin:
          kind: StatChart
          spec:
            calculation: last
            format:
              decimalPlaces: 0
              unit: days
            thresholds:
              steps:
                - color: red
                  value: 0
                - color: yellow
                  value: 7
                - color: green
                  value: 30
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: sum by (Component)(rox_central_cert_exp_hours / 24)
                  seriesNameFormat: '{{Component}}'
    fixable_user_workload_vulnerabilities_over_time:
      kind: Panel
      spec:
        display:
          name: Fixable user workload vulnerabilities over time
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              mode: table
              position: bottom
              size: small
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by(Severity)(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace'',IsFixable="true",IsPlatformWorkload="false"})'
                  seriesNameFormat: '{{Severity}}'
    total_user_fixable_vulnerabilities:
      kind: Panel
      spec:
        display:
          name: Total fixable items in user workloads
        plugin:
          kind: StatChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace'',IsFixable="true",IsPlatformWorkload="false"})'
    violations_by_severity:
      kind: Panel
      spec:
        display:
          name: Policy violations by severity
        plugin:
          kind: BarChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (Severity)(rox_central_policy_violation_namespace_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace''})'
                  seriesNameFormat: '{{Severity}}'
    total_vulnerabilities:
      kind: Panel
      spec:
        display:
          name: Total vulnerable items
        plugin:
          kind: StatChart
          spec:
            calculation: last
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(rox_central_image_vuln_deployment_severity{Cluster=~''$Cluster'',Namespace=~''$Namespace''})'
  refreshInterval: 1m
  variables:
    - kind: ListVariable
      spec:
        allowAllValue: true
        allowMultiple: true
        name: Cluster
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            labelName: Cluster
    - kind: ListVariable
      spec:
        allowAllValue: true
        allowMultiple: true
        name: Namespace
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            labelName: Namespace
DASHBOARD_EOF
    )
    
    # Replace namespace in dashboard YAML
    PERSES_DASHBOARD_YAML=$(echo "$PERSES_DASHBOARD_YAML" | sed "s/namespace: openshift-cluster-observability-operator/namespace: $OBSERVABILITY_OPERATOR_NAMESPACE/g")
    
    # Create all resources at once (batch creation)
    # Use oc apply for all resources - it handles both create and update
    log "Creating/updating PersesDatasource 'rhacs-datasource'..."
    if oc get persesdatasource rhacs-datasource -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "PersesDatasource already exists, updating..."
        echo "$PERSES_DATASOURCE_YAML" | oc apply -f - || error "Failed to update PersesDatasource"
    else
        echo "$PERSES_DATASOURCE_YAML" | oc apply -f - || error "Failed to create PersesDatasource"
    fi
    log "✓ PersesDatasource ready"
    
    log "Creating/updating UIPlugin 'monitoring'..."
    if oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "UIPlugin already exists, updating..."
        echo "$UIPLUGIN_YAML" | oc apply -f - || error "Failed to update UIPlugin"
    else
        echo "$UIPLUGIN_YAML" | oc apply -f - || error "Failed to create UIPlugin"
    fi
    log "✓ UIPlugin ready"
    
    log "Creating/updating PersesDashboard 'rhacs-dashboard'..."
    if oc get persesdashboard rhacs-dashboard -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
        log "PersesDashboard already exists, updating..."
        echo "$PERSES_DASHBOARD_YAML" | oc apply -f - || error "Failed to update PersesDashboard"
    else
        echo "$PERSES_DASHBOARD_YAML" | oc apply -f - || error "Failed to create PersesDashboard"
    fi
    log "✓ PersesDashboard ready"
    
    log "✓ All Perses resources created/updated successfully"
    
    # Now verify all resources together
    log "Waiting for all Perses resources to be ready..."
    VERIFICATION_TIMEOUT=300
    VERIFICATION_ELAPSED=0
    ALL_READY=false
    
    while [ $VERIFICATION_ELAPSED -lt $VERIFICATION_TIMEOUT ]; do
        UIPLUGIN_READY=false
        PERSES_DATASOURCE_READY=false
        PERSES_DASHBOARD_READY=false
        
        # Check UIPlugin
        UIPLUGIN_STATUS=$(oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$UIPLUGIN_STATUS" = "True" ]; then
            UIPLUGIN_READY=true
        fi
        
        # Check PersesDatasource
        PERSES_DATASOURCE_STATUS=$(oc get persesdatasource rhacs-datasource -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$PERSES_DATASOURCE_STATUS" = "True" ]; then
            PERSES_DATASOURCE_READY=true
        fi
        
        # Check PersesDashboard
        PERSES_DASHBOARD_STATUS=$(oc get persesdashboard rhacs-dashboard -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$PERSES_DASHBOARD_STATUS" = "True" ]; then
            PERSES_DASHBOARD_READY=true
        fi
        
        # Log status every 30 seconds
        READY_COUNT=0
        [ "$UIPLUGIN_READY" = true ] && READY_COUNT=$((READY_COUNT + 1))
        [ "$PERSES_DATASOURCE_READY" = true ] && READY_COUNT=$((READY_COUNT + 1))
        [ "$PERSES_DASHBOARD_READY" = true ] && READY_COUNT=$((READY_COUNT + 1))
        
        if [ $READY_COUNT -eq 3 ]; then
            ALL_READY=true
            log "✓ All Perses resources are ready"
            break
        fi
        
        if [ $((VERIFICATION_ELAPSED % 30)) -eq 0 ]; then
            log "Waiting for resources... (${VERIFICATION_ELAPSED}s/${VERIFICATION_TIMEOUT}s) - Ready: $READY_COUNT/3"
            log "  UIPlugin: ${UIPLUGIN_STATUS:-pending}"
            log "  PersesDatasource: ${PERSES_DATASOURCE_STATUS:-pending}"
            log "  PersesDashboard: ${PERSES_DASHBOARD_STATUS:-pending}"
        fi
        
        sleep 10
        VERIFICATION_ELAPSED=$((VERIFICATION_ELAPSED + 10))
    done
    
    if [ "$ALL_READY" = false ]; then
        warning "Some resources may still be initializing. Final status:"
        oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null && log "  UIPlugin: Available" || log "  UIPlugin: Not ready"
        oc get persesdatasource rhacs-datasource -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null && log "  PersesDatasource: Available" || log "  PersesDatasource: Not ready"
        oc get persesdashboard rhacs-dashboard -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null && log "  PersesDashboard: Available" || log "  PersesDashboard: Not ready"
        warning "Proceeding anyway - resources may still be deploying..."
    fi
    
    # Check for Perses pods
    log "Checking for Perses pods..."
    PERSES_PODS=$(oc get pods -n "$OBSERVABILITY_OPERATOR_NAMESPACE" | grep -i perses | grep -v NAME | wc -l || echo "0")
    if [ "$PERSES_PODS" -gt 0 ]; then
        log "✓ Found $PERSES_PODS Perses pod(s)"
        oc get pods -n "$OBSERVABILITY_OPERATOR_NAMESPACE" | grep -i perses || true
    else
        warning "Perses pods not found yet. They may still be starting."
        log "This is normal - Perses deployment may take a few minutes after UIPlugin creation"
    fi
else
    log "Skipping UIPlugin and Perses resources creation - CRD not available"
    log "Note: Metrics and dashboards are still available via Prometheus UI"
fi

# Verify MonitoringStack integration
log "Verifying MonitoringStack integration with UI plugin..."
if oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
    log "✓ MonitoringStack status:"
    oc get monitoringstack rhacs-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null && echo "" || true
fi

# Provide instructions for accessing metrics
log "========================================================="
log "Cluster Observability Operator Setup Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - MonitoringStack 'rhacs-monitoring-stack' created in namespace: $NAMESPACE"
log "  - ScrapeConfig 'rhacs-central-scrape-config' created in namespace: $NAMESPACE"
log "  - Metrics target: ${CENTRAL_SERVICE_FQDN}:${CENTRAL_SERVICE_PORT}"
if [ "$UIPLUGIN_CRD_AVAILABLE" = true ]; then
    log "  - PersesDatasource 'rhacs-datasource' created in namespace: $OBSERVABILITY_OPERATOR_NAMESPACE"
    log "  - PersesDashboard 'rhacs-dashboard' created in namespace: $OBSERVABILITY_OPERATOR_NAMESPACE"
    log "  - UIPlugin 'monitoring' created in namespace: $OBSERVABILITY_OPERATOR_NAMESPACE"
    log "  - Perses dashboards enabled for monitoring UI"
else
    log "  - UIPlugin and Perses resources skipped (CRD not available)"
fi
log ""
log "To view metrics in OpenShift console:"
log "  1. Switch to Administrator perspective"
log "  2. Navigate to: Observe → Metrics"
log "  3. Search for RHACS metrics (e.g., 'rox_' prefix or 'acs_' prefix)"
if [ "$UIPLUGIN_CRD_AVAILABLE" = true ]; then
    log ""
    log "To view Perses dashboards (if UIPlugin is available):"
    log "  1. Navigate to: Observe → Dashboards"
    log "  2. Click 'Create Dashboard' to create custom dashboards"
    log "  3. Add panel → Select Prometheus datasource"
    log "  4. Use queries like: sum(acs_violations_total) or rox_* metrics"
else
    log ""
    log "Note: Perses dashboards require UIPlugin CRD (Technology Preview)"
    log "      Access Prometheus UI directly via port-forward:"
    log "      oc port-forward -n $NAMESPACE svc/prometheus-operated 9090:9090"
fi
log ""
log "To verify MonitoringStack status:"
log "  oc get monitoringstack rhacs-monitoring-stack -n $NAMESPACE"
log ""
log "To verify ScrapeConfig:"
log "  oc get scrapeconfig rhacs-central-scrape-config -n $NAMESPACE"
log ""
log "To verify PersesDatasource:"
log "  oc get persesdatasource rhacs-datasource -n $OBSERVABILITY_OPERATOR_NAMESPACE"
log ""
log "To verify PersesDashboard:"
log "  oc get persesdashboard rhacs-dashboard -n $OBSERVABILITY_OPERATOR_NAMESPACE"
log ""
log "To verify UIPlugin:"
log "  oc get uplugin monitoring -n $OBSERVABILITY_OPERATOR_NAMESPACE"
log ""
log "To check Prometheus pods:"
log "  oc get pods -n $NAMESPACE -l app.kubernetes.io/name=prometheus"
log ""
log "To check Perses pods:"
log "  oc get pods -n $OBSERVABILITY_OPERATOR_NAMESPACE | grep perses"
log ""
log "Note: It may take a few minutes for Prometheus to start scraping metrics."
log "      Perses dashboards may take a few minutes to appear after UIPlugin creation."
log "      Metrics will appear in the OpenShift console once Prometheus has collected data."
log ""
log "If the Cluster Observability Operator is not installed, install it from OperatorHub:"
log "  1. Go to Operators → OperatorHub"
log "  2. Search for 'Cluster Observability Operator'"
log "  3. Install it in the openshift-cluster-observability-operator namespace"
