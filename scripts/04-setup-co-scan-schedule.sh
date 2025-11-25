#!/bin/bash
# Application Setup API Script for RHACS
# Fetches cluster ID and creates compliance scan configuration

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[API-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[API-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[API-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[API-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Source environment variables
if [ -f ~/.bashrc ]; then
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    # Source bashrc with error handling
    set +u  # Temporarily disable unbound variable checking
    if ! source ~/.bashrc; then
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    log "~/.bashrc not found, proceeding with current environment"
fi

# Validate environment variables
if [ -z "$ROX_ENDPOINT" ]; then
    error "ROX_ENDPOINT not set. Please set it in ~/.bashrc"
fi
if [ -z "$ROX_API_TOKEN" ]; then
    error "ROX_API_TOKEN not set. Please set it in ~/.bashrc"
fi
log "✓ Environment variables validated: ROX_ENDPOINT=$ROX_ENDPOINT"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq not found and cannot be installed automatically. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
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
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[0].id')
if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
    error "Failed to extract cluster ID. Response: ${CLUSTER_RESPONSE:0:300}"
fi
log "✓ Cluster ID: $PRODUCTION_CLUSTER_ID"

# Check if acs-catch-all scan configuration already exists
log "Checking if 'acs-catch-all' scan configuration already exists..."
EXISTING_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)

CONFIG_CURL_EXIT_CODE=$?
if [ $CONFIG_CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch existing scan configurations (exit code: $CONFIG_CURL_EXIT_CODE). Response: ${EXISTING_CONFIGS:0:300}"
fi

if [ -z "$EXISTING_CONFIGS" ]; then
    error "Empty response from scan configurations API"
fi

if ! echo "$EXISTING_CONFIGS" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from scan configurations API. Response: ${EXISTING_CONFIGS:0:300}"
fi

EXISTING_SCAN=$(echo "$EXISTING_CONFIGS" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null || echo "")

if [ -n "$EXISTING_SCAN" ] && [ "$EXISTING_SCAN" != "null" ]; then
    log "✓ Scan configuration 'acs-catch-all' already exists (ID: $EXISTING_SCAN)"
    log "Skipping creation..."
    SCAN_CONFIG_ID="$EXISTING_SCAN"
    SKIP_CREATION=true
else
    log "Scan configuration 'acs-catch-all' not found, creating new configuration..."
    SKIP_CREATION=false
fi

# Create compliance scan configuration (only if it doesn't exist)
if [ "$SKIP_CREATION" = "false" ]; then
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
    SCAN_CREATE_EXIT_CODE=$?

    if [ $SCAN_CREATE_EXIT_CODE -ne 0 ]; then
        error "Failed to create compliance scan configuration (exit code: $SCAN_CREATE_EXIT_CODE). Response: ${SCAN_CONFIG_RESPONSE:0:300}"
    fi

    if [ -z "$SCAN_CONFIG_RESPONSE" ]; then
        error "Empty response from scan configuration creation API"
    fi

    if ! echo "$SCAN_CONFIG_RESPONSE" | jq . >/dev/null 2>&1; then
        error "Invalid JSON response from scan configuration creation API. Response: ${SCAN_CONFIG_RESPONSE:0:300}"
    fi

    log "✓ Compliance scan configuration created successfully"
    
    # Get the scan configuration ID from the response
    SCAN_CONFIG_ID=$(echo "$SCAN_CONFIG_RESPONSE" | jq -r '.id')
    if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
        log "Could not extract scan configuration ID from response, trying to get it from configurations list..."
        
        # Get scan configurations to find our configuration
        CONFIGS_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
        CONFIGS_EXIT_CODE=$?

        if [ $CONFIGS_EXIT_CODE -ne 0 ]; then
            error "Failed to get scan configurations list (exit code: $CONFIGS_EXIT_CODE). Response: ${CONFIGS_RESPONSE:0:300}"
        fi

        SCAN_CONFIG_ID=$(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id')
        if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
            error "Could not find 'acs-catch-all' configuration in the list. Available configurations: $(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | .scanName' 2>/dev/null | tr '\n' ' ' || echo "none")"
        else
            log "✓ Found scan configuration ID: $SCAN_CONFIG_ID"
        fi
    else
        log "✓ Scan configuration ID: $SCAN_CONFIG_ID"
    fi
fi

log "Compliance scan schedule setup completed successfully!"
log "Scan configuration ID: $SCAN_CONFIG_ID"
log "Note: Run script 05-trigger-compliance-scan.sh to trigger an immediate scan"
log ""