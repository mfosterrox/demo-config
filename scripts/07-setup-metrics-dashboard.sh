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

# Check if the operator CRD exists (primary API group)
if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
    log "✓ Cluster Observability Operator CRD found (monitoring.rhobs)"
    OBSERVABILITY_OPERATOR_INSTALLED=true
    CRD_API_GROUP="monitoring.rhobs"
elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
    log "✓ Cluster Observability Operator CRD found (monitoring.observability.openshift.io)"
    OBSERVABILITY_OPERATOR_INSTALLED=true
    CRD_API_GROUP="monitoring.observability.openshift.io"
fi

# Check if operator subscription exists
if oc get subscription cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
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
        oc get subscription cluster-observability-operator -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o yaml | grep -A 10 "status:" || true
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
    
    # Wait for CRDs to be registered
    log "Waiting for CRDs to be registered..."
    CRD_WAIT_TIMEOUT=120
    CRD_WAIT_ELAPSED=0
    CRD_AVAILABLE=false
    
    while [ $CRD_WAIT_ELAPSED -lt $CRD_WAIT_TIMEOUT ]; do
        if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
            CRD_AVAILABLE=true
            CRD_API_GROUP="monitoring.rhobs"
            log "✓ CRD monitoringstacks.monitoring.rhobs is available"
            break
        elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
            CRD_AVAILABLE=true
            CRD_API_GROUP="monitoring.observability.openshift.io"
            log "✓ CRD monitoringstacks.monitoring.observability.openshift.io is available"
            break
        fi
        sleep 5
        CRD_WAIT_ELAPSED=$((CRD_WAIT_ELAPSED + 5))
        log "Waiting for CRDs... (${CRD_WAIT_ELAPSED}s/${CRD_WAIT_TIMEOUT}s)"
    done
    
    if [ "$CRD_AVAILABLE" = false ]; then
        error "CRDs not available after waiting. Operator may not be fully installed."
    fi
else
    log "✓ Cluster Observability Operator is already installed"
    
    # Determine which API group to use
    if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        CRD_API_GROUP="monitoring.rhobs"
    elif oc get crd monitoringstacks.monitoring.observability.openshift.io &>/dev/null; then
        CRD_API_GROUP="monitoring.observability.openshift.io"
    else
        warning "Could not determine CRD API group, will try both"
        CRD_API_GROUP="monitoring.rhobs"
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

log "Prometheus endpoint for UIPlugin: $PROMETHEUS_ENDPOINT"

# Create UIPlugin resource for monitoring UI with Perses dashboards
log "Creating UIPlugin resource for monitoring UI with Perses dashboards..."

UIPLUGIN_YAML=$(cat <<EOF
apiVersion: console.openshift.io/v1
kind: UIPlugin
metadata:
  name: monitoring
  namespace: $OBSERVABILITY_OPERATOR_NAMESPACE
spec:
  name: monitoring
  displayName: Monitoring UI Plugin
  type: monitoring
  content:
    resources:
      - name: main
        type: Bundle
        data: |
          name: @openshift-console/dynamic-plugin-sdk
          version: "2.201.0"
          path: ./index.js
          entry: ./index.js
          esm: true
    dependencies:
      - name: '@openshift-console/dynamic-plugin-sdk'
        version: '^2.201.0'
      - name: '@patternfly/react-core'
        version: '^5.0.0'
    plugins:
      - name: monitoring-plugin
        options:
          enabled: true
          rhacmIntegration: false
          incidents: true
          dashboards: true
          datasource:
            prometheus:
              addr: https://${PROMETHEUS_ENDPOINT}
              bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
              wauth: false
EOF
)

# Create UIPlugin
log "Creating UIPlugin 'monitoring'..."
if oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" &>/dev/null; then
    log "UIPlugin 'monitoring' already exists, updating..."
    echo "$UIPLUGIN_YAML" | oc apply -f - || error "Failed to update UIPlugin"
    log "✓ UIPlugin updated successfully"
else
    log "Creating new UIPlugin..."
    echo "$UIPLUGIN_YAML" | oc create -f - || error "Failed to create UIPlugin"
    log "✓ UIPlugin created successfully"
fi

# Wait for UIPlugin to be ready
log "Waiting for UIPlugin to be ready..."
UIPLUGIN_TIMEOUT=300
UIPLUGIN_ELAPSED=0
UIPLUGIN_READY=false

while [ $UIPLUGIN_ELAPSED -lt $UIPLUGIN_TIMEOUT ]; do
    UIPLUGIN_STATUS=$(oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
    if [ "$UIPLUGIN_STATUS" = "True" ]; then
        UIPLUGIN_READY=true
        log "✓ UIPlugin is Available"
        break
    fi
    sleep 10
    UIPLUGIN_ELAPSED=$((UIPLUGIN_ELAPSED + 10))
    log "Waiting for UIPlugin to be ready... (${UIPLUGIN_ELAPSED}s/${UIPLUGIN_TIMEOUT}s)"
done

if [ "$UIPLUGIN_READY" = false ]; then
    warning "UIPlugin may still be initializing. Checking status..."
    oc get uplugin monitoring -n "$OBSERVABILITY_OPERATOR_NAMESPACE" -o yaml | grep -A 10 "status:" || true
    warning "Proceeding anyway - UIPlugin may still be deploying..."
fi

# Check for Perses pods
log "Checking for Perses pods..."
sleep 10  # Give operator time to create Perses resources
PERSES_PODS=$(oc get pods -n "$OBSERVABILITY_OPERATOR_NAMESPACE" | grep -i perses | grep -v NAME | wc -l || echo "0")
if [ "$PERSES_PODS" -gt 0 ]; then
    log "✓ Found $PERSES_PODS Perses pod(s)"
    oc get pods -n "$OBSERVABILITY_OPERATOR_NAMESPACE" | grep -i perses || true
else
    warning "Perses pods not found yet. They may still be starting."
    log "This is normal - Perses deployment may take a few minutes after UIPlugin creation"
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
log "  - UIPlugin 'monitoring' created in namespace: $OBSERVABILITY_OPERATOR_NAMESPACE"
log "  - Perses dashboards enabled for monitoring UI"
log ""
log "To view metrics and dashboards in OpenShift console:"
log "  1. Switch to Administrator perspective"
log "  2. Navigate to: Observe → Metrics (for PromQL queries)"
log "  3. Navigate to: Observe → Dashboards (for Perses dashboards)"
log "  4. Search for RHACS metrics (e.g., 'rox_' prefix or 'acs_' prefix)"
log ""
log "To create RHACS-specific dashboards:"
log "  1. Go to Observe → Dashboards"
log "  2. Click 'Create Dashboard'"
log "  3. Add panel → Select Prometheus datasource"
log "  4. Use queries like: sum(acs_violations_total) or rox_* metrics"
log ""
log "To verify MonitoringStack status:"
log "  oc get monitoringstack rhacs-monitoring-stack -n $NAMESPACE"
log ""
log "To verify ScrapeConfig:"
log "  oc get scrapeconfig rhacs-central-scrape-config -n $NAMESPACE"
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
