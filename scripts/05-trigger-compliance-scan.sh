#!/bin/bash
# Trigger Compliance Scan Script
# Triggers compliance scans for all clusters and monitors their completion

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[COMPLIANCE-SCAN]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-SCAN]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-SCAN] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-SCAN] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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

# Load environment variables from ~/.bashrc (set by script 01)
log "Loading environment variables from ~/.bashrc..."

# Ensure ~/.bashrc exists
if [ ! -f ~/.bashrc ]; then
    error "~/.bashrc not found. Please run script 01-rhacs-setup.sh first to initialize environment variables."
fi

# Clean up any malformed source commands in bashrc
if grep -q "^source $" ~/.bashrc; then
    log "Cleaning up malformed source commands in ~/.bashrc..."
    sed -i '/^source $/d' ~/.bashrc
fi

# Load SCRIPT_DIR and PROJECT_ROOT (set by script 01)
SCRIPT_DIR=$(load_from_bashrc "SCRIPT_DIR")
PROJECT_ROOT=$(load_from_bashrc "PROJECT_ROOT")

# Load required variables (set by script 01)
ROX_ENDPOINT=$(load_from_bashrc "ROX_ENDPOINT")
ROX_API_TOKEN=$(load_from_bashrc "ROX_API_TOKEN")

# Validate required environment variables
if [ -z "$ROX_API_TOKEN" ]; then
    error "ROX_API_TOKEN not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi

if [ -z "$ROX_ENDPOINT" ]; then
    error "ROX_ENDPOINT not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi
log "✓ Required environment variables validated: ROX_ENDPOINT=$ROX_ENDPOINT"

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
        error "jq is required for this script to work correctly. Please install jq manually."
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

log "Starting compliance scan trigger process..."


# Function to wait for scan completion
function wait_for_scan_completion() {
    local config_id="$1"
    local max_wait_time=${SCAN_WAIT_TIMEOUT:-600}  # Default 10 minutes
    local check_interval=10  # Check every 10 seconds
    local elapsed=0
    
    log "Waiting for compliance scan to complete (timeout: ${max_wait_time}s)..."
    
    while [ $elapsed -lt $max_wait_time ]; do
        # Get scan configuration status
        CONFIG_STATUS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
        
        if [ -z "$CONFIG_STATUS" ]; then
            warning "Empty response when checking scan status, continuing..."
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
            continue
        fi
        
        if ! echo "$CONFIG_STATUS" | jq . >/dev/null 2>&1; then
            warning "Invalid JSON response when checking scan status, continuing..."
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
            continue
        fi
        
        # Extract scan status from configuration
        SCAN_STATUS=$(echo "$CONFIG_STATUS" | jq -r ".configurations[]? | select(.id == \"$config_id\") | .lastScanStatus // \"UNKNOWN\"" 2>/dev/null)
        LAST_SCANNED=$(echo "$CONFIG_STATUS" | jq -r ".configurations[]? | select(.id == \"$config_id\") | .lastScanned // \"\"" 2>/dev/null)
        
        if [ -z "$SCAN_STATUS" ] || [ "$SCAN_STATUS" = "null" ]; then
            log "Scan status not yet available, waiting... (${elapsed}s/${max_wait_time}s)"
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
            continue
        fi
        
        log "Scan status: $SCAN_STATUS (elapsed: ${elapsed}s/${max_wait_time}s)"
        
        # Check if scan is still running
        if [[ "$SCAN_STATUS" == "Scanning now" ]] || [[ "$SCAN_STATUS" == "RUNNING" ]] || [[ "$SCAN_STATUS" == "IN_PROGRESS" ]]; then
            if [ $((elapsed % 60)) -eq 0 ]; then
                log "Scan still in progress... (${elapsed}s/${max_wait_time}s)"
            fi
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
            continue
        elif [[ "$SCAN_STATUS" == "COMPLETED" ]] || [[ "$SCAN_STATUS" == "SUCCESS" ]] || [[ "$SCAN_STATUS" == "FINISHED" ]]; then
            log "✓ Compliance scan completed successfully!"
            if [ -n "$LAST_SCANNED" ] && [ "$LAST_SCANNED" != "null" ]; then
                log "Last scanned: $LAST_SCANNED"
            fi
            return 0
        elif [[ "$SCAN_STATUS" == "FAILED" ]] || [[ "$SCAN_STATUS" == "ERROR" ]]; then
            warning "Scan failed with status: $SCAN_STATUS"
            error "Scan failed. Check RHACS UI for details."
        else
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        fi
    done
    
    # Timeout reached
    warning "Scan did not complete within ${max_wait_time}s timeout"
    log "Scan may still be in progress. Check RHACS UI for status."
}

# Trigger scan using scan configuration API
log "Checking for 'acs-catch-all' scan configuration..."
SCAN_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
CURL_EXIT_CODE=$?

if [ $CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch scan configurations (exit code: $CURL_EXIT_CODE). Response: ${SCAN_CONFIGS:0:300}"
fi

if [ -z "$SCAN_CONFIGS" ]; then
    error "Empty response from scan configurations API"
fi

# Check if response is valid JSON
if ! echo "$SCAN_CONFIGS" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from scan configurations API. Response: ${SCAN_CONFIGS:0:300}"
fi

log "✓ Successfully fetched scan configurations"
SCAN_CONFIG_ID=$(echo "$SCAN_CONFIGS" | jq -r '.configurations[]? | select(.scanName == "acs-catch-all") | .id' 2>/dev/null)

if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ] || [ "$SCAN_CONFIG_ID" = "" ]; then
    error "Scan configuration 'acs-catch-all' not found. Please run script 04-setup-co-scan-schedule.sh first to create the scan configuration."
fi

log "✓ Found 'acs-catch-all' scan configuration (ID: $SCAN_CONFIG_ID)"
log "Triggering compliance scan via RHACS API..."

RUN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "{\"scanConfigId\": \"$SCAN_CONFIG_ID\"}" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations/reports/run" 2>&1)
RUN_EXIT_CODE=$?

if [ $RUN_EXIT_CODE -ne 0 ]; then
    error "Failed to trigger scan (exit code: $RUN_EXIT_CODE). Response: ${RUN_RESPONSE:0:300}"
fi

if [ -z "$RUN_RESPONSE" ]; then
    error "Empty response from scan trigger API"
fi

# Check if response indicates success
if ! echo "$RUN_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from scan trigger API. Response: ${RUN_RESPONSE:0:300}"
fi

log "✓ Compliance scan triggered successfully"

# Wait for scan completion
wait_for_scan_completion "$SCAN_CONFIG_ID"

log "✓ Compliance scan trigger process completed successfully!"
