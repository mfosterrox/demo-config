#!/bin/bash
# Application Setup API Script for RHACS
# Fetches cluster ID and creates compliance scan configuration

set -e

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[API-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[API-SETUP]${NC} $1"
    exit 1
}

# Source environment variables
[ -f ~/.bashrc ] && source ~/.bashrc || log "~/.bashrc not found, proceeding with current environment"

# Validate environment variables
[ -z "$ROX_ENDPOINT" ] && error "ROX_ENDPOINT not set. Please set it in ~/.bashrc"
[ -z "$ROX_API_TOKEN" ] && error "ROX_API_TOKEN not set. Please set it in ~/.bashrc"
log "✓ Environment variables validated: ROX_ENDPOINT=$ROX_ENDPOINT"

# Ensure jq is installed
if ! command -v jq &>/dev/null; then
    log "Installing jq..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y jq
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    else
        error "jq not found and cannot be installed automatically"
    fi
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# Fetch cluster ID
log "Fetching cluster ID for 'production' cluster..."
CLUSTER_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v1/clusters" 2>&1)
CLUSTER_CURL_EXIT_CODE=$?

if [ $CLUSTER_CURL_EXIT_CODE -ne 0 ]; then
    error "Cluster API request failed with exit code $CLUSTER_CURL_EXIT_CODE. Response: $CLUSTER_RESPONSE"
fi

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Extract cluster ID
PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[0].id' 2>/dev/null)
if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
    error "Failed to extract cluster ID. Response preview: ${CLUSTER_RESPONSE:0:200}..."
fi
log "✓ Cluster ID: $PRODUCTION_CLUSTER_ID"

# Create compliance scan configuration
log "Creating compliance scan configuration 'acs-catch-all'..."
SCAN_CONFIG_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "{
        \"scanName\": \"acs-catch-all\",
        \"scanConfig\": {
            \"oneTimeScan\": false,
            \"profiles\": [
                \"ocp4-cis\",
                \"ocp4-cis-node\",
                \"ocp4-e8\",
                \"ocp4-high\",
                \"ocp4-high-node\",
                \"ocp4-nerc-cip\",
                \"ocp4-nerc-cip-node\",
                \"ocp4-pci-dss\",
                \"ocp4-pci-dss-node\",
                \"ocp4-stig\",
                \"ocp4-stig-node\"
            ],
            \"scanSchedule\": {
                \"intervalType\": \"DAILY\",
                \"hour\": 0,
                \"minute\": 0
            },
            \"description\": \"Daily compliance scan for all profiles\"
        },
        \"clusters\": [
            \"$PRODUCTION_CLUSTER_ID\"
        ]
    }" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)

if [ $? -eq 0 ]; then
    log "✓ Compliance scan configuration created successfully"
else
    error "Failed to create compliance scan configuration. Response: $SCAN_CONFIG_RESPONSE"
fi

# Verify the scan configuration was created and trigger a run
log "Verifying scan configuration and triggering compliance run..."

# Get the scan configuration ID from the response
SCAN_CONFIG_ID=$(echo "$SCAN_CONFIG_RESPONSE" | jq -r '.id' 2>/dev/null)
if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
    log "Could not extract scan configuration ID from response, trying to get it from configurations list..."
    
    # Get scan configurations to find our configuration
    CONFIGS_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
    
    if [ $? -eq 0 ]; then
        SCAN_CONFIG_ID=$(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null)
        if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
            log "✓ Found scan configuration ID: $SCAN_CONFIG_ID"
        else
            log "Could not find 'acs-catch-all' configuration in the list"
            log "Available configurations:"
            echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | .scanName' 2>/dev/null || log "No configurations found"
        fi
    else
        log "Failed to get scan configurations list"
    fi
else
    log "✓ Scan configuration ID: $SCAN_CONFIG_ID"
fi

# Trigger a compliance run if we have the ID
if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
    log "Triggering compliance scan run with ID: $SCAN_CONFIG_ID"
    RUN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-raw "{\"scanConfigId\": \"$SCAN_CONFIG_ID\"}" \
        "$ROX_ENDPOINT/v2/compliance/scan/configurations/reports/run" 2>&1)
    
    RUN_CURL_EXIT_CODE=$?
    
    if [ $RUN_CURL_EXIT_CODE -eq 0 ]; then
        log "✓ Compliance scan run triggered successfully"
        log "Run response: $RUN_RESPONSE"
    else
        log "Failed to trigger compliance scan run. Exit code: $RUN_CURL_EXIT_CODE"
        log "Run response: $RUN_RESPONSE"
    fi
else
    log "Cannot trigger compliance run - no valid scan configuration ID found"
fi

log "Compliance scan schedule setup completed successfully!"