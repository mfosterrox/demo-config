#!/bin/bash
# RHACS Secured Cluster Setup Script
# Creates RHACS secured cluster services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-SETUP]${NC} $1"
    exit 1
}

# Configuration variables
NAMESPACE="tssc-acs"
CLUSTER_NAME="ads-cluster"
TOKEN_NAME="setup-script-$(date +%d-%m-%Y_%H-%M-%S)"
TOKEN_ROLE="Admin"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Check if Central is running
if ! oc get deployment central -n $NAMESPACE &>/dev/null; then
    error "RHACS Central not found in namespace $NAMESPACE"
fi

# Wait for Central to be ready
log "Waiting for Central to be ready..."
oc wait --for=condition=Available deployment/central -n $NAMESPACE --timeout=300s

# Extract admin credentials
log "Extracting admin credentials..."
ADMIN_PASSWORD=$(oc get secret central-htpasswd -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

# Extract external Central endpoint
ROX_ENDPOINT=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.host}'):443
if [ -z "$ROX_ENDPOINT" ]; then
    error "Failed to extract Central endpoint"
fi

log "Central endpoint: $ROX_ENDPOINT"

# Test connectivity to Central endpoint
log "Testing connectivity to Central endpoint..."
if ! curl -k -s --connect-timeout 10 "https://$ROX_ENDPOINT" >/dev/null; then
    error "Cannot connect to Central at $ROX_ENDPOINT"
fi

# Create API token programmatically
log "Creating API token: $TOKEN_NAME"
ROX_API_TOKEN=$(curl -k -X POST \
  -u "admin:$ADMIN_PASSWORD" \
  -H "Content-Type: application/json" \
  --data "{\"name\":\"$TOKEN_NAME\",\"role\":\"$TOKEN_ROLE\"}" \
  "https://$ROX_ENDPOINT/v1/apitokens/generate" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null)

if [ -z "$ROX_API_TOKEN" ]; then
    error "Failed to create API token"
fi

# Export environment variables for roxctl
export ROX_API_TOKEN
export ROX_ENDPOINT

log "API token created successfully"

# Download roxctl if not available
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, installing to system location..."
    
    # Download roxctl to temporary location first
    curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl"
    
    if [ $? -eq 0 ]; then
        # Move to system-wide location
        sudo mv /tmp/roxctl /usr/local/bin/roxctl
        sudo chmod +x /usr/local/bin/roxctl
        
        # Verify installation
        if command -v roxctl &>/dev/null; then
            log "✓ roxctl installed successfully to /usr/local/bin/roxctl"
            ROXCTL_CMD="roxctl"
        else
            error "Failed to install roxctl to system location"
        fi
    else
        error "Failed to download roxctl"
    fi
else
    log "roxctl already available in system PATH"
    ROXCTL_CMD="roxctl"
fi

# Test roxctl connectivity using external endpoint with -e flag
log "Testing roxctl connectivity..."
if ! $ROXCTL_CMD central whoami -e "$ROX_ENDPOINT" --insecure-skip-tls-verify >/dev/null 2>&1; then
    error "roxctl authentication failed for endpoint: $ROX_ENDPOINT"
fi

# Generate init bundle using external endpoint with -e flag
log "Generating init bundle for cluster: $CLUSTER_NAME"
if $ROXCTL_CMD central init-bundles generate $CLUSTER_NAME \
  -e "$ROX_ENDPOINT" \
  --output-secrets cluster_init_bundle.yaml --insecure-skip-tls-verify 2>&1 | grep -q "AlreadyExists"; then
    log "Init bundle already exists, proceeding with existing configuration..."
    # Check if secured cluster services already exist
    if oc get securedcluster same-cluster-secured-services -n $NAMESPACE >/dev/null 2>&1; then
        log "SecuredCluster resource already exists, skipping creation..."
        SKIP_TO_FINAL_OUTPUT=true
    else
        log "Creating SecuredCluster resource..."
        SKIP_TO_FINAL_OUTPUT=false
    fi
else
    if [ ! -f cluster_init_bundle.yaml ]; then
        error "Failed to generate init bundle"
    fi
    SKIP_TO_FINAL_OUTPUT=false
fi

# Apply init bundle (only if not skipping)
if [ "$SKIP_TO_FINAL_OUTPUT" = "false" ]; then
    log "Applying init bundle secrets..."
    oc apply -f cluster_init_bundle.yaml -n $NAMESPACE

    # Create SecuredCluster resource with INTERNAL endpoint
    log "Creating SecuredCluster resource with internal endpoint..."
cat <<EOF | oc apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: same-cluster-secured-services
  namespace: $NAMESPACE
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
EOF
fi

# Wait for deployment (only if not skipping)
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
    while ! oc get $resource_type $resource_name -n $NAMESPACE >/dev/null 2>&1; do
        if [ $wait_count -ge 60 ]; then  # 5 minutes max wait for creation
            warning "$resource_type/$resource_name was not created within 5 minutes"
            return 1
        fi
        sleep 5
        wait_count=$((wait_count + 1))
        echo -n "."
    done
    echo ""
    
    if [ "$resource_type" = "daemonset" ]; then
        # For DaemonSets, check if desired number of pods are scheduled and ready
        log "$resource_type/$resource_name created, waiting for all pods to be ready..."
        local ready_timeout=$((timeout / 5))  # Check every 5 seconds
        local check_count=0
        
        while [ $check_count -lt $ready_timeout ]; do
            local status=$(oc get daemonset $resource_name -n $NAMESPACE -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null)
            local desired=$(echo $status | cut -d',' -f1)
            local ready=$(echo $status | cut -d',' -f2)
            
            if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$desired" != "0" ]; then
                log "✓ $resource_type/$resource_name is ready ($ready/$desired pods running)"
                return 0
            fi
            
            if [ -n "$desired" ] && [ -n "$ready" ]; then
                log "DaemonSet $resource_name: $ready/$desired pods ready..."
            fi
            
            sleep 5
            check_count=$((check_count + 1))
        done
        
        warning "$resource_type/$resource_name readiness timeout (not all pods ready within ${timeout}s)"
        return 1
    else
        # For other resources (Deployments), use standard condition waiting
        log "$resource_type/$resource_name created, waiting for $condition condition..."
        if oc wait --for=condition=$condition $resource_type/$resource_name -n $NAMESPACE --timeout=${timeout}s; then
            log "✓ $resource_type/$resource_name is ready"
            return 0
        else
            warning "$resource_type/$resource_name $condition condition timeout"
            return 1
        fi
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

# Check pod status
FAILED_PODS=$(oc get pods -n $NAMESPACE --field-selector=status.phase!=Running,status.phase!=Succeeded -o name | wc -l)
if [ "$FAILED_PODS" -gt 0 ]; then
    warning "$FAILED_PODS pods are not in Running/Succeeded state"
    oc get pods -n $NAMESPACE
fi
fi

# Generate roxapi token and save to bashrc
log "Generating roxapi token..."

# Create API token using admin credentials
ROXAPI_TOKEN=$(curl -k -X POST \
  -u "admin:$ADMIN_PASSWORD" \
  -H "Content-Type: application/json" \
  --data "{\"name\":\"roxapi-token-$(date +%Y%m%d-%H%M%S)\",\"role\":\"Admin\"}" \
  "https://$ROX_ENDPOINT/v1/apitokens/generate" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null)

if [ -n "$ROXAPI_TOKEN" ]; then
    log "✓ roxapi token generated successfully"
    
    # Save token and endpoint to bashrc
    log "Saving ROX_API_TOKEN and ROX_ENDPOINT to ~/.bashrc..."
    echo "export ROX_API_TOKEN=\"$ROXAPI_TOKEN\"" >> ~/.bashrc
    echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT\"" >> ~/.bashrc
    
    # Export for current session
    export ROX_API_TOKEN="$ROXAPI_TOKEN"
    export ROX_ENDPOINT="$ROX_ENDPOINT"
    
    log "✓ Environment variables saved to ~/.bashrc"
else
    warning "Failed to generate roxapi token"
fi

# Clean up temporary files
rm -f cluster_init_bundle.yaml
# roxctl is now installed permanently to /usr/local/bin/roxctl

log "RHACS same-cluster configuration completed successfully!"
log "========================================================="
log "RHACS UI:     https://$ROX_ENDPOINT"
log "---------------------------------------------------------"
log "User:         admin"
log "Password:     $ADMIN_PASSWORD"
log "---------------------------------------------------------"
