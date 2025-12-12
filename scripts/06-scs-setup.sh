#!/bin/bash
# RHACS Secured Cluster Services Setup Script
# Generates init bundle and creates SecuredCluster resource

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-SCS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-SCS]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-SCS] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-SCS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

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

# Load environment variables from ~/.bashrc
log "Loading environment variables from ~/.bashrc..."

# RHACS operator namespace
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Verify namespace exists
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists..."
if ! oc get namespace "$RHACS_OPERATOR_NAMESPACE" &>/dev/null; then
    error "Namespace '$RHACS_OPERATOR_NAMESPACE' does not exist. Please run the Central install script first."
fi
log "✓ Namespace '$RHACS_OPERATOR_NAMESPACE' exists"

# Get ROX_ENDPOINT from Central route
log ""
log "Retrieving ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found. Please ensure Central is installed and ready."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Extracted ROX_ENDPOINT from route: $ROX_ENDPOINT"

# Save to ~/.bashrc
sed -i '/^export ROX_ENDPOINT=/d' ~/.bashrc 2>/dev/null || true
echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT\"" >> ~/.bashrc
export ROX_ENDPOINT="$ROX_ENDPOINT"

# Load ROX_API_TOKEN from ~/.bashrc
ROX_API_TOKEN=$(load_from_bashrc "ROX_API_TOKEN")

# Verify ROX_API_TOKEN is set
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN not found in ~/.bashrc. Please ensure it is set from previous scripts."
fi
log "✓ ROX_API_TOKEN loaded"

# Get ADMIN_PASSWORD from secret
log ""
log "Retrieving ADMIN_PASSWORD from secret..."
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    error "Admin password secret 'central-htpasswd' not found in namespace $RHACS_OPERATOR_NAMESPACE"
fi
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
if [ -z "$ADMIN_PASSWORD" ]; then
    error "Failed to decode admin password from secret"
fi
log "✓ Admin password retrieved"

# Normalize ROX_ENDPOINT for API calls (add :443 if no port)
normalize_rox_endpoint() {
    local input="$1"
    input="${input#https://}"
    input="${input#http://}"
    input="${input%/}"
    if [[ "$input" != *:* ]]; then
        input="${input}:443"
    fi
    echo "$input"
}

ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
log "Central endpoint: $ROX_ENDPOINT (normalized for API calls: $ROX_ENDPOINT_NORMALIZED)"

# Download roxctl if not available
ROXCTL_CMD=""
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, downloading..."
    
    # Determine OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Map architecture
    case "$ARCH" in
        x86_64)
            ROXCTL_ARCH="amd64"
            ;;
        aarch64|arm64)
            ROXCTL_ARCH="arm64"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            ;;
    esac
    
    # Map OS
    case "$OS" in
        linux)
            ROXCTL_OS="Linux"
            ;;
        darwin)
            ROXCTL_OS="Darwin"
            ;;
        *)
            error "Unsupported OS: $OS"
            ;;
    esac
    
    # Get RHACS version from CSV
    RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
    if [ -z "$RHACS_VERSION" ]; then
        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
    fi
    
    # Download roxctl
    ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/${ROXCTL_OS}/roxctl"
    ROXCTL_TMP="/tmp/roxctl"
    
    log "Downloading roxctl from: $ROXCTL_URL"
    if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
        # Try latest if version-specific download fails
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${ROXCTL_OS}/roxctl"
        log "Retrying with latest version: $ROXCTL_URL"
        if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
            error "Failed to download roxctl. Please install it manually."
        fi
    fi
    
    chmod +x "$ROXCTL_TMP"
    ROXCTL_CMD="$ROXCTL_TMP"
    log "✓ roxctl downloaded to $ROXCTL_TMP"
else
    ROXCTL_CMD="roxctl"
    log "✓ roxctl found in PATH"
fi

# Test roxctl connectivity using password authentication
log "Verifying roxctl connectivity..."
if ! $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" central whoami --password "$ADMIN_PASSWORD" --insecure-skip-tls-verify >/dev/null 2>&1; then
    ROXCTL_ERROR=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" central whoami --password "$ADMIN_PASSWORD" --insecure-skip-tls-verify 2>&1 || true)
    error "roxctl authentication failed. Error: $ROXCTL_ERROR"
fi
log "✓ roxctl connectivity verified"

# Get cluster name
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(oc config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's/[^a-zA-Z0-9-]/-/g' || echo "local-cluster")
fi

# Check if SecuredCluster already exists
SECURED_CLUSTER_NAME="rhacs-secured-cluster-services"
SKIP_TO_FINAL_OUTPUT=false

if oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    log "SecuredCluster resource '$SECURED_CLUSTER_NAME' already exists; skipping init bundle generation and SecuredCluster installation."
    SKIP_TO_FINAL_OUTPUT=true
    
    # Verify auto-lock setting
    CURRENT_AUTO_LOCK=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.processBaselines.autoLock}' 2>/dev/null)
    if [ "$CURRENT_AUTO_LOCK" != "Enabled" ]; then
        log "Updating SecuredCluster to enable process baseline auto-lock..."
        oc patch securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --type='merge' -p '{"spec":{"processBaselines":{"autoLock":"Enabled"}}}'
        if [ $? -eq 0 ]; then
            log "✓ Process baseline auto-lock enabled on existing SecuredCluster"
        else
            warning "Failed to update auto-lock setting"
        fi
    else
        log "✓ Process baseline auto-lock already enabled"
    fi
fi

# Generate init bundle if needed
INIT_BUNDLE_EXISTS=false
if [ "$SKIP_TO_FINAL_OUTPUT" = "false" ]; then
    log "Generating init bundle for cluster: $CLUSTER_NAME"
    log "Using endpoint: $ROX_ENDPOINT_NORMALIZED"
    
    # Generate init bundle using password authentication
    INIT_BUNDLE_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
      central init-bundles generate "$CLUSTER_NAME" \
      --output-secrets cluster_init_bundle.yaml \
      --password "$ADMIN_PASSWORD" \
      --insecure-skip-tls-verify 2>&1) || INIT_BUNDLE_EXIT_CODE=$?
    
    # Check if init bundle already exists
    if echo "$INIT_BUNDLE_OUTPUT" | grep -q "AlreadyExists"; then
        log "Init bundle already exists in RHACS Central"
        INIT_BUNDLE_EXISTS=true
    elif [ ! -f cluster_init_bundle.yaml ]; then
        error "Failed to generate init bundle. roxctl output: ${INIT_BUNDLE_OUTPUT:0:500}"
    else
        log "✓ Init bundle generated successfully"
        INIT_BUNDLE_EXISTS=false
    fi
    
    # Apply init bundle secrets
    if [ "$INIT_BUNDLE_EXISTS" = "false" ]; then
        log "Applying init bundle secrets..."
        oc apply -f cluster_init_bundle.yaml -n "$RHACS_OPERATOR_NAMESPACE"
        log "✓ Init bundle secrets applied"
    else
        log "Init bundle secrets already exist, skipping application..."
    fi
    
    # Create SecuredCluster resource
    log "Creating SecuredCluster resource..."
cat <<EOF | oc apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: $SECURED_CLUSTER_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  clusterName: "$CLUSTER_NAME"
  centralEndpoint: "$ROX_ENDPOINT"
  admissionControl:
    listenOnCreates: true
    listenOnEvents: true 
    listenOnUpdates: true
    enforceOnCreates: false
    enforceOnUpdates: false
    scanInline: true
    disableBypass: false
    timeoutSeconds: 20
  auditLogs:
    collection: Auto
  perNode:
    collector:
      collection: EBPF
      imageFlavor: Regular
      resources:
        limits:
          cpu: 750m
          memory: 1Gi
        requests:
          cpu: 50m
          memory: 320Mi
    taintToleration: TolerateTaints
  scanner:
    analyzer:
      scaling:
        autoScaling: Enabled
        maxReplicas: 5
        minReplicas: 1
        replicas: 3
      resources:
        limits:
          cpu: 2000m
          memory: 4Gi
        requests:
          cpu: 1000m
          memory: 1500Mi
    scannerComponent: AutoSense
  processBaselines:
    autoLock: Enabled
EOF
    
    log "✓ SecuredCluster resource created"
    
    # Verify auto-lock setting
    sleep 2
    AUTO_LOCK_STATUS=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.processBaselines.autoLock}' 2>/dev/null)
    if [ "$AUTO_LOCK_STATUS" = "Enabled" ]; then
        log "✓ Process baseline auto-lock verified: Enabled"
    else
        warning "Process baseline auto-lock setting not found or not Enabled (current: $AUTO_LOCK_STATUS)"
    fi
fi

# Wait for SecuredCluster components to be ready
if [ "$SKIP_TO_FINAL_OUTPUT" = "false" ]; then
    log "Waiting for SecuredCluster components to be ready..."
    
    # Function to wait for resource to exist and then be ready
    wait_for_resource() {
        local resource_type=$1
        local resource_name=$2
        local condition=$3
        local timeout=${4:-300}
        
        log "Waiting for $resource_type/$resource_name to be created..."
        local wait_count=0
        while ! oc get $resource_type $resource_name -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
            if [ $wait_count -ge 60 ]; then
                warning "$resource_type/$resource_name was not created within 5 minutes"
                return 1
            fi
            sleep 5
            wait_count=$((wait_count + 1))
            echo -n "."
        done
        echo ""
        
        if [ "$resource_type" = "daemonset" ]; then
            log "$resource_type/$resource_name created, checking pod readiness..."
            local check_count=0
            local check_interval=5
            local max_checks=$((timeout / check_interval))
            
            while [ $check_count -lt $max_checks ]; do
                local desired=$(oc get daemonset $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
                local ready=$(oc get daemonset $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                
                if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" != "0" ] && [ "$desired" = "$ready" ]; then
                    log "✓ $resource_type/$resource_name is ready ($ready/$desired pods running)"
                    return 0
                fi
                
                if [ $((check_count % 6)) -eq 0 ] && [ $check_count -gt 0 ]; then
                    log "  $resource_type/$resource_name: $ready/$desired pods ready..."
                fi
                
                sleep $check_interval
                check_count=$((check_count + 1))
            done
            
            # Final check - if we're close, consider it ready
            local final_desired=$(oc get daemonset $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
            local final_ready=$(oc get daemonset $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
            if [ "$final_desired" != "0" ] && [ "$final_ready" != "0" ]; then
                log "✓ $resource_type/$resource_name is ready ($final_ready/$final_desired pods running)"
                return 0
            fi
            
            warning "$resource_type/$resource_name readiness timeout ($final_ready/$final_desired pods ready after ${timeout}s)"
            return 1
        else
            # For deployments, check replica status directly
            log "$resource_type/$resource_name created, checking replica status..."
            local check_count=0
            local check_interval=5
            local max_checks=$((timeout / check_interval))
            
            while [ $check_count -lt $max_checks ]; do
                local replicas=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
                local ready_replicas=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                local available_replicas=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
                
                # Consider ready if we have at least 1 ready replica and it matches desired, or if available >= 1
                if [ "$replicas" != "0" ] && [ "$ready_replicas" != "0" ] && [ "$ready_replicas" = "$replicas" ]; then
                    log "✓ $resource_type/$resource_name is ready ($ready_replicas/$replicas replicas ready)"
                    return 0
                fi
                
                # Also check if available replicas are ready (sometimes readyReplicas lags)
                if [ "$available_replicas" != "0" ] && [ "$available_replicas" = "$replicas" ]; then
                    log "✓ $resource_type/$resource_name is ready ($available_replicas/$replicas replicas available)"
                    return 0
                fi
                
                if [ $((check_count % 6)) -eq 0 ] && [ $check_count -gt 0 ]; then
                    log "  $resource_type/$resource_name: $ready_replicas/$replicas replicas ready, $available_replicas available..."
                fi
                
                sleep $check_interval
                check_count=$((check_count + 1))
            done
            
            # Final check
            local final_replicas=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
            local final_ready=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local final_available=$(oc get deployment $resource_name -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
            
            if [ "$final_ready" != "0" ] || [ "$final_available" != "0" ]; then
                log "✓ $resource_type/$resource_name is ready ($final_ready/$final_replicas replicas ready, $final_available available)"
                return 0
            fi
            
            warning "$resource_type/$resource_name readiness timeout ($final_ready/$final_replicas replicas ready after ${timeout}s)"
            return 1
        fi
    }
    
    # Wait for sensor deployment
    wait_for_resource "deployment" "sensor" "Available" 300
    
    # Wait for admission-control deployment  
    wait_for_resource "deployment" "admission-control" "Available" 300
    
    # Wait for collector daemonset
    wait_for_resource "daemonset" "collector" "" 300
    
    # Verification
    log "Verifying deployment..."
    FAILED_PODS=$(oc get pods -n "$RHACS_OPERATOR_NAMESPACE" --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | wc -l)
    if [ "$FAILED_PODS" -gt 0 ]; then
        warning "$FAILED_PODS pods are not in Running/Succeeded state"
        oc get pods -n "$RHACS_OPERATOR_NAMESPACE"
    fi
fi

# Clean up temporary files
rm -f cluster_init_bundle.yaml

log ""
log "========================================================="
log "RHACS Secured Cluster Services Setup Completed!"
log "========================================================="
log "Namespace: $RHACS_OPERATOR_NAMESPACE"
log "SecuredCluster Resource: $SECURED_CLUSTER_NAME"
log "Cluster Name: $CLUSTER_NAME"
log "Central Endpoint: $ROX_ENDPOINT"
log "========================================================="
log ""
log "Secured Cluster Services are now configured and ready."
log ""
