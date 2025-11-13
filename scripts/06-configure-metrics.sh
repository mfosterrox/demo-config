#!/bin/bash
# RHACS Prometheus Metrics Configuration Script
# Configures RHACS to export Prometheus metrics with custom metric categories

set -eo pipefail

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

# Source environment variables
if [ -f ~/.bashrc ]; then
    log "Sourcing ~/.bashrc..."
    
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    set +u  # Temporarily disable unbound variable checking
    if ! source ~/.bashrc 2>/dev/null; then
        log "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    log "~/.bashrc not found, proceeding with current environment"
fi

# Validate environment variables
if [[ -z "$ROX_API_TOKEN" ]]; then
    error "ROX_API_TOKEN needs to be set"
    exit 1
fi

if [[ -z "$ROX_ENDPOINT" ]]; then
    error "ROX_ENDPOINT needs to be set"
    exit 1
fi

# Normalize ROX_ENDPOINT (ensure it has https:// prefix)
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# Remove trailing slash if present
ROX_ENDPOINT="${ROX_ENDPOINT%/}"

log "Starting RHACS Prometheus metrics configuration..."
log "RHACS Endpoint: $ROX_ENDPOINT"

# Function to make authenticated API calls
function roxcurl() {
    curl -sk -H "Authorization: Bearer $ROX_API_TOKEN" "$@"
}

# Test connectivity to RHACS API
log "Testing connectivity to RHACS API..."
if ! roxcurl "$ROX_ENDPOINT/v1/config" >/dev/null 2>&1; then
    error "Cannot connect to RHACS API at $ROX_ENDPOINT"
    exit 1
fi
log "✓ Successfully connected to RHACS API"

# Get current configuration
log "Retrieving current RHACS configuration..."
CURRENT_CONFIG=$(roxcurl "$ROX_ENDPOINT/v1/config")

if [ -z "$CURRENT_CONFIG" ]; then
    error "Failed to retrieve current configuration"
    exit 1
fi

log "✓ Current configuration retrieved"

# Check if metrics configuration already exists
METRICS_CONFIG=$(echo "$CURRENT_CONFIG" | jq -r '.privateConfig.metrics // empty' 2>/dev/null)

# Prepare metrics configuration
# Enable Prometheus metrics export and add custom metric descriptors
log "Configuring Prometheus metrics export..."

# Merge with existing configuration
log "Merging metrics configuration with existing config..."

# Update configuration to add/merge the component_severity metric descriptor
# This follows the pattern from the documentation: adding to descriptors using +=
UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq '
  # Ensure privateConfig exists
  .privateConfig = (.privateConfig // {}) |
  # Ensure metrics exists
  .privateConfig.metrics = (.privateConfig.metrics // {}) |
  # Ensure policyViolations exists
  .privateConfig.metrics.policyViolations = (.privateConfig.metrics.policyViolations // {}) |
  # Set gathering period if not already set
  .privateConfig.metrics.policyViolations.gatheringPeriodMinutes = (.privateConfig.metrics.policyViolations.gatheringPeriodMinutes // 60) |
  # Ensure descriptors exists
  .privateConfig.metrics.policyViolations.descriptors = (.privateConfig.metrics.policyViolations.descriptors // {}) |
  # Add component_severity descriptor (will merge with existing if present)
  .privateConfig.metrics.policyViolations.descriptors.component_severity = {
    "labels": ["component", "severity"]
  }
' 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$UPDATED_CONFIG" ]; then
    error "Failed to merge metrics configuration"
    log "Attempting alternative merge approach..."
    # Alternative approach: use += to add to descriptors
    UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq '.privateConfig.metrics.policyViolations.descriptors += {
      "component_severity": {
        "labels": ["component", "severity"]
      }
    }' 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$UPDATED_CONFIG" ]; then
        error "Failed to merge metrics configuration with alternative approach"
        exit 1
    fi
fi

# Apply the updated configuration
log "Applying updated configuration to RHACS..."
RESPONSE=$(roxcurl -X PATCH \
    -H "Content-Type: application/json" \
    -d "$UPDATED_CONFIG" \
    "$ROX_ENDPOINT/v1/config" 2>&1)

if [ $? -eq 0 ]; then
    log "✓ Metrics configuration applied successfully"
    
    # Verify the configuration was applied
    log "Verifying configuration..."
    sleep 2
    VERIFY_CONFIG=$(roxcurl "$ROX_ENDPOINT/v1/config")
    VERIFY_METRICS=$(echo "$VERIFY_CONFIG" | jq -r '.privateConfig.metrics.policyViolations.descriptors.component_severity // empty' 2>/dev/null)
    
    if [ -n "$VERIFY_METRICS" ] && [ "$VERIFY_METRICS" != "null" ]; then
        log "✓ Configuration verified successfully"
        log "  Metric: component_severity"
        log "  Labels: component, severity"
        log "  Gathering period: 60 minutes"
    else
        warning "Configuration may not have been applied correctly"
        log "Response: $RESPONSE"
    fi
else
    error "Failed to apply metrics configuration"
    log "Response: $RESPONSE"
    exit 1
fi

# Display metrics endpoint information
log ""
log "========================================================="
log "Prometheus Metrics Configuration Complete"
log "========================================================="
log "Metrics endpoint: $ROX_ENDPOINT/metrics"
log "Custom metric: component_severity"
log "Labels: component, severity"
log "Gathering period: 60 minutes"
log ""
log "To scrape metrics with Prometheus, configure:"
log "  - job_name: 'rhacs'"
log "    scrape_interval: 60s"
log "    static_configs:"
log "      - targets: ['$ROX_ENDPOINT']"
log "========================================================="

if [ "$SCRIPT_FAILED" = true ]; then
    warning "Metrics configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS Prometheus metrics configuration completed successfully!"
fi

