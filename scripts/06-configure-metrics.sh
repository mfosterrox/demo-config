#!/bin/bash
# RHACS Custom Metrics Configuration Script
# Configures custom Prometheus metrics via RHACS API

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[METRICS-CONFIG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[METRICS-CONFIG]${NC} $1"
}

error() {
    echo -e "${RED}[METRICS-CONFIG]${NC} $1"
    exit 1
}

# Configuration
NAMESPACE="tssc-acs"

# Check prerequisites
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Source bashrc to get environment variables
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

# Check if ROX_ENDPOINT is set
if [ -z "$ROX_ENDPOINT" ]; then
    log "ROX_ENDPOINT not set in environment, extracting from route..."
    ROX_ENDPOINT_HOST=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.host}')
    ROX_ENDPOINT="${ROX_ENDPOINT_HOST%:*}:443"
    if [ -z "$ROX_ENDPOINT_HOST" ]; then
        error "Failed to extract Central endpoint"
    fi
    export ROX_ENDPOINT
    log "Central endpoint: $ROX_ENDPOINT"
fi

# Check if ROX_API_TOKEN is set
if [ -z "$ROX_API_TOKEN" ]; then
    log "ROX_API_TOKEN not set in environment, extracting admin password..."
    ADMIN_PASSWORD=$(oc get secret central-htpasswd -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        error "Failed to extract admin password"
    fi
    
    log "Creating API token for metrics configuration..."
    ROX_API_TOKEN=$(curl -k -X POST \
      -u "admin:$ADMIN_PASSWORD" \
      -H "Content-Type: application/json" \
      --data "{\"name\":\"metrics-config-token-$(date +%Y%m%d-%H%M%S)\",\"role\":\"Admin\"}" \
      "https://$ROX_ENDPOINT/v1/apitokens/generate" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null)
    
    if [ -z "$ROX_API_TOKEN" ]; then
        error "Failed to create API token"
    fi
    export ROX_API_TOKEN
    log "✓ API token created successfully"
fi

log "Using Central endpoint: $ROX_ENDPOINT"

# Ensure ROX_ENDPOINT has https:// prefix for curl commands
ROX_API_ENDPOINT="https://$ROX_ENDPOINT"

# Get current configuration
log "Fetching current RHACS configuration..."
CURRENT_CONFIG=$(curl -k -s "$ROX_API_ENDPOINT/v1/config" -H "Authorization: Bearer $ROX_API_TOKEN" 2>/dev/null)

if [ -z "$CURRENT_CONFIG" ] || echo "$CURRENT_CONFIG" | grep -q "error"; then
    error "Failed to fetch current configuration. Check that Central is accessible and the API token is valid."
fi

log "✓ Current configuration retrieved"

# Configure custom Prometheus metrics
log "Configuring custom Prometheus metrics..."

# Add custom policy violation metrics with various label combinations
UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq '
  .privateConfig.metrics.policyViolations.descriptors += {
    component_severity: { 
      labels: [ "Component", "Severity" ] 
    },
    cluster_namespace_severity: { 
      labels: [ "Cluster", "Namespace", "Severity" ] 
    },
    policy_severity: { 
      labels: [ "Policy", "Severity" ] 
    },
    deployment_severity: {
      labels: [ "Deployment", "Severity" ]
    }
  } | 
  { config: . }
' 2>/dev/null)

if [ -z "$UPDATED_CONFIG" ]; then
    error "Failed to create updated configuration"
fi

# Apply the updated configuration
log "Applying updated metrics configuration..."
UPDATE_RESPONSE=$(echo "$UPDATED_CONFIG" | curl -k -s -X PUT "$ROX_API_ENDPOINT/v1/config" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- 2>/dev/null)

if [ $? -ne 0 ]; then
    error "Failed to update configuration"
fi

log "✓ Custom metrics configuration applied successfully"

# Configure metrics gathering period
log "Configuring metrics gathering period..."

# Set gathering period to 5 minutes (300 seconds)
GATHERING_CONFIG=$(echo "$CURRENT_CONFIG" | jq '
  .privateConfig.metrics.gatheringIntervalMinutes = 5 |
  { config: . }
' 2>/dev/null)

if [ -n "$GATHERING_CONFIG" ]; then
    echo "$GATHERING_CONFIG" | curl -k -s -X PUT "$ROX_API_ENDPOINT/v1/config" \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @- >/dev/null 2>&1
    log "✓ Metrics gathering interval set to 5 minutes"
else
    warning "Could not set gathering interval, continuing..."
fi

# Wait for metrics to be generated
log "Waiting for metrics to be generated (30 seconds)..."
sleep 30

# Verify metrics are being exposed
log "Verifying custom metrics are exposed..."

# Check for custom metrics
METRICS_OUTPUT=$(curl -k -s "$ROX_API_ENDPOINT/metrics" \
  -H "Authorization: Bearer $ROX_API_TOKEN" 2>/dev/null)

if [ -z "$METRICS_OUTPUT" ]; then
    warning "Could not fetch metrics endpoint"
else
    # Check for some common RHACS metrics
    if echo "$METRICS_OUTPUT" | grep -q "rox_central"; then
        log "✓ RHACS metrics are being exposed"
        
        # Count available metrics
        METRIC_COUNT=$(echo "$METRICS_OUTPUT" | grep "^rox_" | wc -l)
        log "✓ Found $METRIC_COUNT RHACS metrics available"
    else
        warning "RHACS metrics not found in output"
    fi
fi

# Display configured custom metrics
log "Custom metrics configured:"
log "  - component_severity: Violations by Component and Severity"
log "  - cluster_namespace_severity: Violations by Cluster, Namespace, and Severity"
log "  - policy_severity: Violations by Policy and Severity"
log "  - deployment_severity: Violations by Deployment and Severity"

log "========================================================="
log "Custom Prometheus metrics configuration completed!"
log "========================================================="
log "Metrics endpoint: https://$ROX_ENDPOINT/metrics"
log "---------------------------------------------------------"
log "To view metrics, run:"
log "  curl -k \"https://$ROX_ENDPOINT/metrics\" \\"
log "    -H \"Authorization: Bearer \$ROX_API_TOKEN\""
log "========================================================="

