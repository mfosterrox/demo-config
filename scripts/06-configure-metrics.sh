#!/bin/bash
# RHACS Custom Metrics Configuration Script
# Configures custom Prometheus metrics via RHACS API

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[METRICS-CONFIG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[METRICS-CONFIG]${NC} $1"
}

error() {
    echo -e "${RED}[METRICS-CONFIG]${NC} $1"
    SCRIPT_FAILED=true
}

# Configuration
DEFAULT_NAMESPACE="tssc-acs"
FALLBACK_NAMESPACE="stackrox"
NAMESPACE="$DEFAULT_NAMESPACE"

# Check prerequisites
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Resolve RHACS namespace with fallback
if ! oc get ns "$NAMESPACE" &>/dev/null || ! oc -n "$NAMESPACE" get route central &>/dev/null; then
    if oc get ns "$FALLBACK_NAMESPACE" &>/dev/null && oc -n "$FALLBACK_NAMESPACE" get route central &>/dev/null; then
        NAMESPACE="$FALLBACK_NAMESPACE"
        log "Default namespace $DEFAULT_NAMESPACE not ready for RHACS; using fallback namespace $NAMESPACE"
    else
        warning "RHACS Central route not found in $DEFAULT_NAMESPACE or $FALLBACK_NAMESPACE"
    fi
fi

# Source bashrc to get environment variables
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

# Check if ROX_ENDPOINT is set
if [ -z "$ROX_ENDPOINT" ]; then
    log "ROX_ENDPOINT not set in environment, extracting from route..."
    ROX_ENDPOINT_HOST=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -z "$ROX_ENDPOINT_HOST" ] && [ "$NAMESPACE" != "$FALLBACK_NAMESPACE" ]; then
        log "Central route not found in $DEFAULT_NAMESPACE; checking fallback namespace $FALLBACK_NAMESPACE"
        ROX_ENDPOINT_HOST=$(oc get route central -n $FALLBACK_NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null)
        if [ -n "$ROX_ENDPOINT_HOST" ]; then
            NAMESPACE="$FALLBACK_NAMESPACE"
            log "Using fallback namespace $NAMESPACE for Central endpoint"
        fi
    fi
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
CURRENT_CONFIG=$(curl -k -s "$ROX_API_ENDPOINT/v1/config" -H "Authorization: Bearer $ROX_API_TOKEN" 2>&1)
CURL_EXIT_CODE=$?

if [ $CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch current configuration (curl exit code: $CURL_EXIT_CODE)"
    log "Response: $CURRENT_CONFIG"
fi

if [ -z "$CURRENT_CONFIG" ] || echo "$CURRENT_CONFIG" | grep -q "error"; then
    error "Failed to fetch current configuration. Check that Central is accessible and the API token is valid."
    log "Response preview: ${CURRENT_CONFIG:0:500}"
fi

log "✓ Current configuration retrieved"

# Debug: Check config structure
log "Checking configuration structure..."
if echo "$CURRENT_CONFIG" | jq -e '.config.privateConfig.metrics' >/dev/null 2>&1; then
    log "✓ Config structure has privateConfig.metrics"
elif echo "$CURRENT_CONFIG" | jq -e '.privateConfig.metrics' >/dev/null 2>&1; then
    log "✓ Config structure has privateConfig.metrics (direct)"
else
    warning "Config structure may be different than expected"
    log "Available top-level keys:"
    echo "$CURRENT_CONFIG" | jq -r 'keys[]' 2>/dev/null | head -10 || log "Could not parse config structure"
fi

# Configure custom Prometheus metrics (all in one update)
log "Configuring Prometheus metrics..."

# Try to extract config if wrapped in { config: ... }
CONFIG_TO_UPDATE="$CURRENT_CONFIG"
if echo "$CURRENT_CONFIG" | jq -e '.config' >/dev/null 2>&1; then
    log "Config is wrapped in 'config' object, extracting..."
    CONFIG_TO_UPDATE=$(echo "$CURRENT_CONFIG" | jq '.config')
fi

# Configure everything: custom policy violation metrics, enable predefined metrics, and set gathering intervals
UPDATED_CONFIG=$(echo "$CONFIG_TO_UPDATE" | jq '
  # Ensure privateConfig.metrics exists
  if .privateConfig.metrics == null then .privateConfig.metrics = {} else . end |
  # Set global metrics gathering interval
  .privateConfig.metrics.gatheringIntervalMinutes = 5 |
  # Enable metrics exposure
  if .publicConfig == null then .publicConfig = {} else . end |
  .publicConfig.telemetry.enabled = true |
  # Enable policy violations metrics (predefined)
  if .privateConfig.metrics.policyViolations == null then .privateConfig.metrics.policyViolations = {} else . end |
  .privateConfig.metrics.policyViolations.gatheringIntervalMinutes = 5 |
  .privateConfig.metrics.policyViolations.predefinedMetrics = [
    "rox_central_policy_violation_namespace_severity",
    "rox_central_policy_violation_deployment_severity"
  ] |
  # Enable image vulnerability metrics
  if .privateConfig.metrics.imageVulnerabilities == null then .privateConfig.metrics.imageVulnerabilities = {} else . end |
  .privateConfig.metrics.imageVulnerabilities.gatheringIntervalMinutes = 5 |
  .privateConfig.metrics.imageVulnerabilities.predefinedMetrics = [
    "rox_central_image_vuln_namespace_severity",
    "rox_central_image_vuln_deployment_severity",
    "rox_central_image_vuln_cve_severity"
  ] |
  # Enable node vulnerability metrics
  if .privateConfig.metrics.nodeVulnerabilities == null then .privateConfig.metrics.nodeVulnerabilities = {} else . end |
  .privateConfig.metrics.nodeVulnerabilities.gatheringIntervalMinutes = 5 |
  .privateConfig.metrics.nodeVulnerabilities.predefinedMetrics = [
    "rox_central_node_vuln_node_severity",
    "rox_central_node_vuln_component_severity",
    "rox_central_node_vuln_cve_severity"
  ]
' 2>&1)

JQ_EXIT_CODE=$?
if [ $JQ_EXIT_CODE -ne 0 ] || [ -z "$UPDATED_CONFIG" ]; then
    error "Failed to create updated configuration with jq (exit code: $JQ_EXIT_CODE)"
    log "jq error output: $UPDATED_CONFIG"
    log "Attempting to show config structure..."
    echo "$CONFIG_TO_UPDATE" | jq '.privateConfig.metrics' 2>/dev/null || echo "$CONFIG_TO_UPDATE" | jq '.' | head -50
fi

# Wrap in config object if original was wrapped
if echo "$CURRENT_CONFIG" | jq -e '.config' >/dev/null 2>&1; then
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq '{ config: . }')
fi

log "Applying comprehensive metrics configuration..."
log "Sending PUT request to $ROX_API_ENDPOINT/v1/config"

UPDATE_RESPONSE=$(echo "$UPDATED_CONFIG" | curl -k -s -w "\n%{http_code}" -X PUT "$ROX_API_ENDPOINT/v1/config" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @- 2>&1)

HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -n 1)
RESPONSE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')

log "API Response HTTP Code: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
    log "API Response Body:"
    echo "$RESPONSE_BODY" | head -20
fi

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    log "✓ Metrics configuration applied successfully (HTTP $HTTP_CODE)"
else
    error "Failed to update configuration (HTTP $HTTP_CODE)"
    log "Full response:"
    echo "$RESPONSE_BODY"
    log ""
    log "Troubleshooting:"
    log "1. Verify API token has Admin role: curl -k -s \"$ROX_API_ENDPOINT/v1/me\" -H \"Authorization: Bearer \$ROX_API_TOKEN\" | jq ."
    log "2. Check config endpoint: curl -k -s \"$ROX_API_ENDPOINT/v1/config\" -H \"Authorization: Bearer \$ROX_API_TOKEN\" | jq '.config.privateConfig.metrics'"
fi

# Wait for metrics to be generated
log "Waiting for metrics to be generated (30 seconds)..."
sleep 30

# Verify metrics are being exposed
log "Verifying metrics are exposed and can be scraped..."

# Check for metrics endpoint
METRICS_OUTPUT=$(curl -k -s "$ROX_API_ENDPOINT/metrics" \
  -H "Authorization: Bearer $ROX_API_TOKEN" 2>/dev/null)

# Verify metrics endpoint is accessible and contains RHACS metrics
log "Testing metrics endpoint accessibility..."
if [ -z "$METRICS_OUTPUT" ]; then
    warning "Could not fetch metrics endpoint - telemetry may not be enabled or endpoint not accessible"
else
    log "✓ Metrics endpoint is accessible"
    
    # Verify specific metric exists to confirm metrics are enabled and scrapable
    log "Verifying metrics are enabled and scrapable..."
    TEST_METRIC="rox_central_policy_violation_namespace_severity"
    METRIC_CHECK=$(curl -k -s "$ROX_API_ENDPOINT/metrics" \
      -H "Authorization: Bearer $ROX_API_TOKEN" 2>/dev/null | grep "$TEST_METRIC" | head -1)
    
    if [ -n "$METRIC_CHECK" ]; then
        log "✓ Metrics verification successful - metric '$TEST_METRIC' found"
        log "Sample metric output:"
        echo "$METRIC_CHECK" | head -1 | sed 's/^/  /'
    else
        warning "Metric '$TEST_METRIC' not found - metrics may still be generating"
        log "Checking for any RHACS metrics..."
        ANY_METRIC=$(curl -k -s "$ROX_API_ENDPOINT/metrics" \
          -H "Authorization: Bearer $ROX_API_TOKEN" 2>/dev/null | grep "^rox_central" | head -1)
        if [ -n "$ANY_METRIC" ]; then
            log "✓ Found RHACS metrics (metrics are enabled):"
            echo "$ANY_METRIC" | sed 's/^/  /'
        else
            warning "No RHACS metrics found - verify metrics configuration"
        fi
    fi
    
    # Verify each enabled metric category
    log ""
    log "Verifying enabled metrics..."
    
    # Check Policy Violation metrics
    if echo "$METRICS_OUTPUT" | grep -q "rox_central_policy_violation_namespace_severity"; then
        log "✓ Policy violation namespace/severity metric found"
    else
        warning "Policy violation namespace/severity metric not found (may need time to generate)"
    fi
    
    if echo "$METRICS_OUTPUT" | grep -q "rox_central_policy_violation_deployment_severity"; then
        log "✓ Policy violation deployment/severity metric found"
    else
        warning "Policy violation deployment/severity metric not found (may need time to generate)"
    fi
    
    # Check Image Vulnerability metrics
    if echo "$METRICS_OUTPUT" | grep -q "rox_central_image_vuln_namespace_severity"; then
        log "✓ Image vulnerability namespace/severity metric found"
    else
        warning "Image vulnerability namespace/severity metric not found (may need time to generate)"
    fi
    
    if echo "$METRICS_OUTPUT" | grep -q "rox_central_image_vuln_deployment_severity"; then
        log "✓ Image vulnerability deployment/severity metric found"
    else
        warning "Image vulnerability deployment/severity metric not found (may need time to generate)"
    fi
    
    # Check Node Vulnerability metrics
    if echo "$METRICS_OUTPUT" | grep -q "rox_central_node_vuln_node_severity"; then
        log "✓ Node vulnerability node/severity metric found"
    else
        warning "Node vulnerability node/severity metric not found (may need time to generate)"
    fi
    
    # Count total RHACS metrics
    METRIC_COUNT=$(echo "$METRICS_OUTPUT" | grep "^rox_central" | wc -l)
    log "✓ Total RHACS metrics available: $METRIC_COUNT"
fi

# Display configured metrics
log "========================================================="
if [ "$SCRIPT_FAILED" = true ]; then
    warning "Prometheus metrics configuration completed with errors. Review the output above."
else
    log "Prometheus metrics configuration completed!"
fi
log "========================================================="
log ""
log "Enabled Policy Violation Metrics:"
log "  - rox_central_policy_violation_namespace_severity"
log "  - rox_central_policy_violation_deployment_severity"
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

