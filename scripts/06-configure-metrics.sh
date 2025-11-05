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

# Configure custom Prometheus metrics (all in one update)
log "Configuring Prometheus metrics..."

# Configure everything: custom policy violation metrics, enable predefined metrics, and set gathering intervals
UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq '
  # Set global metrics gathering interval
  .privateConfig.metrics.gatheringIntervalMinutes = 5 |
  # Add custom policy violation metrics
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
  # Enable policy violations metrics gathering (5 minutes)
  .privateConfig.metrics.policyViolations.gatheringIntervalMinutes = 5 |
  # Enable image vulnerability metrics
  .privateConfig.metrics.imageVulnerabilities.gatheringIntervalMinutes = 5 |
  .privateConfig.metrics.imageVulnerabilities.predefinedMetrics = [
    "rox_central_image_vuln_namespace_severity",
    "rox_central_image_vuln_deployment_severity",
    "rox_central_image_vuln_cve_severity"
  ] |
  # Enable node vulnerability metrics
  .privateConfig.metrics.nodeVulnerabilities.gatheringIntervalMinutes = 5 |
  .privateConfig.metrics.nodeVulnerabilities.predefinedMetrics = [
    "rox_central_node_vuln_node_severity",
    "rox_central_node_vuln_component_severity",
    "rox_central_node_vuln_cve_severity"
  ] |
  { config: . }
' 2>/dev/null)

if [ -z "$UPDATED_CONFIG" ]; then
    error "Failed to create updated configuration with jq"
fi

log "Applying comprehensive metrics configuration..."
UPDATE_RESPONSE=$(echo "$UPDATED_CONFIG" | curl -k -s -w "\n%{http_code}" -X PUT "$ROX_API_ENDPOINT/v1/config" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- 2>/dev/null)

HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -n 1)
RESPONSE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    log "✓ Metrics configuration applied successfully (HTTP $HTTP_CODE)"
else
    error "Failed to update configuration (HTTP $HTTP_CODE). Response: $RESPONSE_BODY"
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

# Display configured metrics
log "========================================================="
log "Prometheus metrics configuration completed!"
log "========================================================="
log ""
log "Custom Policy Violation Metrics:"
log "  - component_severity: Violations by Component and Severity"
log "  - cluster_namespace_severity: Violations by Cluster, Namespace, and Severity"
log "  - policy_severity: Violations by Policy and Severity"
log "  - deployment_severity: Violations by Deployment and Severity"
log ""
log "Enabled Image Vulnerability Metrics:"
log "  - rox_central_image_vuln_namespace_severity"
log "  - rox_central_image_vuln_deployment_severity"
log "  - rox_central_image_vuln_cve_severity"
log ""
log "Enabled Node Vulnerability Metrics:"
log "  - rox_central_node_vuln_node_severity"
log "  - rox_central_node_vuln_component_severity"
log "  - rox_central_node_vuln_cve_severity"
log ""
log "Gathering Intervals:"
log "  - Policy Violations: 5 minutes"
log "  - Image Vulnerabilities: 5 minutes"
log "  - Node Vulnerabilities: 5 minutes"
log ""
log "---------------------------------------------------------"
log "Metrics endpoint: https://$ROX_ENDPOINT/metrics"
log "---------------------------------------------------------"
log "To view metrics, run:"
log "  curl -k \"https://$ROX_ENDPOINT/metrics\" \\"
log "    -H \"Authorization: Bearer \$ROX_API_TOKEN\""
log "========================================================="

