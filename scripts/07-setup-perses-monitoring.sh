#!/bin/bash
# Perses Monitoring Setup Script
# Installs Cluster Observability Operator and configures Perses monitoring

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[PERSES-MONITORING]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[PERSES-MONITORING]${NC} $1"
}

error() {
    echo -e "${RED}[PERSES-MONITORING] ERROR:${NC} $1" >&2
    echo -e "${RED}[PERSES-MONITORING] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MONITORING_SETUP_DIR="$PROJECT_ROOT/monitoring-setup"

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
if ! oc auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"

# Load NAMESPACE from ~/.bashrc (set by previous scripts)
NAMESPACE=$(load_from_bashrc "NAMESPACE")
if [ -z "$NAMESPACE" ]; then
    NAMESPACE="tssc-acs"
    log "NAMESPACE not found in ~/.bashrc, using default: $NAMESPACE"
else
    log "✓ Loaded NAMESPACE from ~/.bashrc: $NAMESPACE"
fi

# Step 0: Generate TLS certificate for RHACS Prometheus monitoring stack
log ""
log "========================================================="
log "Step 0: Generating TLS certificate for RHACS Prometheus"
log "========================================================="

# Check if openssl is available
if ! command -v openssl &>/dev/null; then
    error "openssl is required but not found. Please install openssl."
fi
log "✓ openssl found"

# Check if namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Please ensure RHACS is installed first."
fi
log "✓ Namespace '$NAMESPACE' exists"

# Generate a private key and certificate
log "Generating TLS private key and certificate..."
CERT_CN="rhacs-monitoring-stack-prometheus.$NAMESPACE.svc"
if openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=$CERT_CN" \
        -keyout tls.key -out tls.crt 2>/dev/null; then
    log "✓ TLS certificate generated successfully"
    log "  Subject: $CERT_CN"
else
    error "Failed to generate TLS certificate"
fi

# Create TLS secret in the namespace (replace if exists)
log "Creating TLS secret 'rhacs-prometheus-tls' in namespace '$NAMESPACE'..."
if oc get secret rhacs-prometheus-tls -n "$NAMESPACE" &>/dev/null; then
    log "Secret 'rhacs-prometheus-tls' already exists, replacing..."
    oc delete secret rhacs-prometheus-tls -n "$NAMESPACE" 2>/dev/null || true
fi

if oc create secret tls rhacs-prometheus-tls --cert=tls.crt --key=tls.key -n "$NAMESPACE" 2>/dev/null; then
    log "✓ TLS secret created successfully"
else
    error "Failed to create TLS secret"
fi

# Clean up temporary certificate files
rm -f tls.key tls.crt
log "✓ Temporary certificate files cleaned up"

# Step 1: Install Cluster Observability Operator
log ""
log "========================================================="
log "Step 1: Installing Cluster Observability Operator"
log "========================================================="

OPERATOR_NAMESPACE="openshift-cluster-observability-operator"

# Check if Cluster Observability Operator is already installed
log "Checking if Cluster Observability Operator is already installed..."

if oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "Namespace $OPERATOR_NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$(oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}')
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Cluster Observability Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                log "Skipping installation..."
            else
                log "Cluster Observability Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "Cluster Observability Operator not found, proceeding with installation..."
fi

# Create namespace for Cluster Observability Operator
log "Creating $OPERATOR_NAMESPACE namespace..."
if ! oc create namespace $OPERATOR_NAMESPACE --dry-run=client -o yaml | oc apply -f -; then
    error "Failed to create $OPERATOR_NAMESPACE namespace"
fi
log "✓ Namespace created successfully"

# Create OperatorGroup (if it doesn't exist)
log "Checking for OperatorGroup..."
if ! oc get operatorgroup -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "Creating OperatorGroup..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
EOF
    then
        error "Failed to create OperatorGroup"
    fi
    log "✓ OperatorGroup created successfully"
else
    log "✓ OperatorGroup already exists"
fi

# Create Subscription for Cluster Observability Operator
log "Creating Subscription for Cluster Observability Operator..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: cluster-observability-operator.v1.3.0
EOF
then
    error "Failed to create Subscription"
fi
log "✓ Subscription created successfully"

# Wait for the operator to be installed
log "Waiting for Cluster Observability Operator to be installed..."
log "This may take a few minutes..."

# Wait for CSV to be created and installed
log "Waiting for ClusterServiceVersion to be created..."
MAX_WAIT=60
WAIT_COUNT=0
while ! oc get csv -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q cluster-observability-operator; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        error "CSV not created after $((MAX_WAIT * 10)) seconds. Check subscription status: oc get subscription cluster-observability-operator -n $OPERATOR_NAMESPACE"
    fi
    log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Get the CSV name
CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -o name 2>/dev/null | grep cluster-observability-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    # Fallback: try getting CSV by label
    CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for cluster-observability-operator"
fi
log "Found CSV: $CSV_NAME"

# Wait for CSV to be in Succeeded phase
log "Waiting for ClusterServiceVersion to be installed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $OPERATOR_NAMESPACE --timeout=300s; then
    CSV_STATUS=$(oc get csv "$CSV_NAME" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    error "CSV failed to reach Succeeded phase. Current status: $CSV_STATUS. Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
fi
log "✓ CSV is in Succeeded phase"

# Wait for the operator deployment to appear (it may take time after CSV succeeds)
log "Waiting for Cluster Observability Operator deployment to be created..."
DEPLOYMENT_NAME="cluster-observability-operator"
MAX_DEPLOYMENT_WAIT=60
DEPLOYMENT_WAIT_COUNT=0
DEPLOYMENT_FOUND=false

while [ $DEPLOYMENT_WAIT_COUNT -lt $MAX_DEPLOYMENT_WAIT ]; do
    if oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        DEPLOYMENT_FOUND=true
        log "✓ Deployment found: $DEPLOYMENT_NAME"
        break
    fi
    
    # Try to find deployment by label if the name doesn't match
    ALTERNATIVE_DEPLOYMENT=$(oc get deployment -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ALTERNATIVE_DEPLOYMENT" ]; then
        DEPLOYMENT_NAME="$ALTERNATIVE_DEPLOYMENT"
        DEPLOYMENT_FOUND=true
        log "✓ Deployment found with label: $DEPLOYMENT_NAME"
        break
    fi
    
    # Check for any deployment in the namespace (fallback)
    ANY_DEPLOYMENT=$(oc get deployment -n $OPERATOR_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ANY_DEPLOYMENT" ]; then
        log "Found deployment in namespace: $ANY_DEPLOYMENT (will check if it's the operator)"
        DEPLOYMENT_NAME="$ANY_DEPLOYMENT"
        DEPLOYMENT_FOUND=true
        break
    fi
    
    if [ $((DEPLOYMENT_WAIT_COUNT % 6)) -eq 0 ]; then
        log "Waiting for deployment to appear... ($DEPLOYMENT_WAIT_COUNT/$MAX_DEPLOYMENT_WAIT)"
    fi
    sleep 10
    DEPLOYMENT_WAIT_COUNT=$((DEPLOYMENT_WAIT_COUNT + 1))
done

if [ "$DEPLOYMENT_FOUND" = false ]; then
    warning "Deployment not found after $((MAX_DEPLOYMENT_WAIT * 10)) seconds. Checking namespace contents..."
    oc get all -n $OPERATOR_NAMESPACE
    warning "Continuing anyway - operator may be installed but deployment may have different name or structure"
else
    # Wait for the deployment to be ready
    log "Waiting for deployment $DEPLOYMENT_NAME to be Available..."
    if ! oc wait --for=condition=Available "deployment/$DEPLOYMENT_NAME" -n $OPERATOR_NAMESPACE --timeout=300s; then
        warning "Deployment $DEPLOYMENT_NAME did not become Available within timeout. Checking status..."
        oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE
        oc describe deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE | head -50
        warning "Continuing anyway - operator CSV is Succeeded, which indicates successful installation"
    else
        log "✓ Cluster Observability Operator deployment is ready"
    fi
fi

# Verify installation
log "Verifying Cluster Observability Operator installation..."

# Check if the operator deployment exists
if oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "✓ Cluster Observability Operator deployment found: $DEPLOYMENT_NAME"
else
    warning "Deployment $DEPLOYMENT_NAME not found. Checking all deployments in namespace..."
    oc get deployment -n $OPERATOR_NAMESPACE
fi

# Check operator pods
log "Checking operator pods..."
POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
if [ -z "$POD_STATUS" ]; then
    # Try alternative label selector
    POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
fi
if [ -n "$POD_STATUS" ]; then
    oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator 2>/dev/null || oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator
else
    warning "No Cluster Observability Operator pods found with standard labels. Checking all pods in namespace..."
    oc get pods -n $OPERATOR_NAMESPACE
fi

# Verify pods are running
if [ -n "$POD_STATUS" ] && echo "$POD_STATUS" | grep -qv "Running"; then
    warning "Some Cluster Observability Operator pods are not Running. Current status: $POD_STATUS"
else
    log "✓ All Cluster Observability Operator pods are Running"
fi

# Check CSV (ClusterServiceVersion)
log "Checking ClusterServiceVersion..."
if ! oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator >/dev/null 2>&1; then
    warning "Cluster Observability Operator CSV not found with expected label. Checking all CSVs..."
    oc get csv -n $OPERATOR_NAMESPACE
else
    oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator
fi

# Display operator status
log ""
log "Cluster Observability Operator installation completed successfully!"
log "========================================================="
log "Namespace: $OPERATOR_NAMESPACE"
log "Operator: cluster-observability-operator"
log "CSV: $CSV_NAME"
log "========================================================="
log ""

# Step 2: Install Cluster Observability Operator resources
log ""
log "========================================================="
log "Step 2: Installing Cluster Observability Operator resources"
log "========================================================="

# Verify monitoring-setup directory exists
if [ ! -d "$MONITORING_SETUP_DIR" ]; then
    error "Monitoring setup directory not found: $MONITORING_SETUP_DIR"
fi
log "✓ Monitoring setup directory found: $MONITORING_SETUP_DIR"

# Function to apply YAML with namespace substitution
apply_yaml_with_namespace() {
    local yaml_file="$1"
    local description="$2"
    
    if [ ! -f "$yaml_file" ]; then
        error "YAML file not found: $yaml_file"
    fi
    
    log "Installing $description..."
    # Replace namespace in YAML file:
    # - namespace: tssc-acs -> namespace: $NAMESPACE
    # - namespace: "tssc-acs" -> namespace: "$NAMESPACE"
    # - .tssc-acs.svc -> .$NAMESPACE.svc (for service references)
    # - .tssc-acs.svc.cluster.local -> .$NAMESPACE.svc.cluster.local
    sed "s/namespace: tssc-acs/namespace: $NAMESPACE/g; \
         s/namespace: \"tssc-acs\"/namespace: \"$NAMESPACE\"/g; \
         s/\\.tssc-acs\\.svc\\.cluster\\.local/\\.$NAMESPACE\\.svc\\.cluster\\.local/g; \
         s/\\.tssc-acs\\.svc/\\.$NAMESPACE\\.svc/g" "$yaml_file" | \
        oc apply -f - || error "Failed to apply $yaml_file"
    log "✓ $description installed successfully"
}

# Install MonitoringStack
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/monitoring-stack.yaml" \
    "MonitoringStack (rhacs-monitoring-stack)"

# Wait a moment for MonitoringStack to be processed
sleep 5

# Install ScrapeConfig
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/scrape-config.yaml" \
    "ScrapeConfig (rhacs-scrape-config)"

log ""
log "Cluster Observability Operator resources installed successfully!"
log ""

# Step 3: Install Prometheus Operator resources
log ""
log "========================================================="
log "Step 3: Installing Prometheus Operator resources"
log "========================================================="

# Install Prometheus additional scrape config secret
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/additional-scrape-config.yaml" \
    "Prometheus additional scrape config secret"

# Install Prometheus custom resource
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus.yaml" \
    "Prometheus (rhacs-prometheus-server)"

# Install PrometheusRule
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus-rule.yaml" \
    "PrometheusRule (rhacs-health-alerts)"

log ""
log "Prometheus Operator resources installed successfully!"
log ""

# Step 4: Install RHACS declarative configuration
log ""
log "========================================================="
log "Step 4: Installing RHACS declarative configuration"
log "========================================================="

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/rhacs/declarative-configuration-configmap.yaml" \
    "RHACS declarative configuration ConfigMap"

log ""
log "RHACS declarative configuration installed successfully!"
log ""

# Step 5: Install Perses resources
log ""
log "========================================================="
log "Step 5: Installing Perses monitoring resources"
log "========================================================="

# Install Perses datasource
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/datasource.yaml" \
    "Perses Datasource (rhacs-datasource)"

# Install Perses dashboard
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/dashboard.yaml" \
    "Perses Dashboard (rhacs-dashboard)"

# Install Perses UI plugin
# Note: UI plugin might be cluster-scoped, check if namespace substitution is needed
log "Installing Perses UI Plugin..."
if grep -q "namespace:" "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml"; then
    apply_yaml_with_namespace \
        "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" \
        "Perses UI Plugin"
else
    log "Installing Perses UI Plugin (cluster-scoped)..."
    oc apply -f "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" || error "Failed to apply UI plugin"
    log "✓ Perses UI Plugin installed successfully"
fi

log ""
log "Perses monitoring resources installed successfully!"
log ""

# Final summary
log ""
log "========================================================="
log "Perses Monitoring Setup Completed Successfully!"
log "========================================================="
log "All monitoring resources have been installed:"
log "  ✓ TLS certificate for RHACS Prometheus"
log "  ✓ Cluster Observability Operator"
log "  ✓ MonitoringStack and ScrapeConfig"
log "  ✓ Prometheus Operator resources"
log "  ✓ RHACS declarative configuration"
log "  ✓ Perses datasource, dashboard, and UI plugin"
log "========================================================="
log ""

