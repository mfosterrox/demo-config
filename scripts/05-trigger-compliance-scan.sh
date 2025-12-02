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

# Function to make authenticated API calls
function roxcurl() {
    curl -skL -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        -w "\n%{http_code}" "$@"
}

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

# Try to trigger using scan configuration first (preferred method)
log "Checking for 'acs-catch-all' scan configuration..."
SCAN_CONFIGS=""
SCAN_CONFIG_ERROR=""

SCAN_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
CURL_EXIT_CODE=$?

if [ $CURL_EXIT_CODE -eq 0 ] && [ -n "$SCAN_CONFIGS" ]; then
    # Check if response is valid JSON
    if echo "$SCAN_CONFIGS" | jq . >/dev/null 2>&1; then
        log "✓ Successfully fetched scan configurations"
        SCAN_CONFIG_ID=$(echo "$SCAN_CONFIGS" | jq -r '.configurations[]? | select(.scanName == "acs-catch-all") | .id' 2>/dev/null)
        
        if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ] && [ "$SCAN_CONFIG_ID" != "" ]; then
            log "✓ Found 'acs-catch-all' scan configuration (ID: $SCAN_CONFIG_ID)"
            log "Triggering compliance scan using scan configuration..."
            
            RUN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
                -H "Authorization: Bearer $ROX_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data-raw "{\"scanConfigId\": \"$SCAN_CONFIG_ID\"}" \
                "$ROX_ENDPOINT/v2/compliance/scan/configurations/reports/run" 2>&1)
            RUN_EXIT_CODE=$?
            
            if [ $RUN_EXIT_CODE -eq 0 ] && [ -n "$RUN_RESPONSE" ]; then
                # Check if response indicates success
                if echo "$RUN_RESPONSE" | jq . >/dev/null 2>&1; then
                    log "✓ Compliance scan triggered successfully using scan configuration"
                    
                    # Wait for scan completion with timeout and retry logic
                    wait_for_scan_completion "$SCAN_CONFIG_ID"
                    exit 0
                else
                    warning "Scan trigger API returned non-JSON response, falling back to legacy method..."
                    log "Response: ${RUN_RESPONSE:0:300}"
                fi
            else
                warning "Failed to trigger scan using configuration (exit code: $RUN_EXIT_CODE), falling back to legacy method..."
                if [ -n "$RUN_RESPONSE" ]; then
                    log "Error response: ${RUN_RESPONSE:0:300}"
                fi
            fi
        else
            log "Scan configuration 'acs-catch-all' not found in response, using legacy trigger method..."
            log "Available scan configurations: $(echo "$SCAN_CONFIGS" | jq -r '.configurations[]?.scanName // "none"' 2>/dev/null | tr '\n' ' ')"
        fi
    else
        warning "Response from scan configurations API is not valid JSON, using legacy trigger method..."
        log "Response preview: ${SCAN_CONFIGS:0:200}"
    fi
else
    if [ $CURL_EXIT_CODE -ne 0 ]; then
        warning "Could not fetch scan configurations (curl exit code: $CURL_EXIT_CODE), using legacy trigger method..."
    else
        warning "Empty response from scan configurations API, using legacy trigger method..."
    fi
    if [ -n "$SCAN_CONFIGS" ]; then
        log "Response: ${SCAN_CONFIGS:0:200}"
    fi
fi

# Fallback: Get all cluster IDs and trigger legacy compliance runs
log "Fetching cluster IDs for legacy compliance trigger..."
CLUSTERS_FULL_RESPONSE=$(roxcurl "$ROX_ENDPOINT/v1/clusters" 2>&1)
CLUSTERS_EXIT_CODE=$?

CLUSTERS_HTTP_CODE=$(extract_http_code "$CLUSTERS_FULL_RESPONSE")
CLUSTERS_RESPONSE=$(extract_body "$CLUSTERS_FULL_RESPONSE")

if [ $CLUSTERS_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch clusters (exit code: $CLUSTERS_EXIT_CODE)"
    if [ -n "$CLUSTERS_RESPONSE" ]; then
        log "Response: ${CLUSTERS_RESPONSE:0:200}"
    fi
    exit 1
fi

if [ -z "$CLUSTERS_RESPONSE" ]; then
    error "Empty response from clusters API (HTTP $CLUSTERS_HTTP_CODE)"
    exit 1
fi

# Check if response is HTML (error page or redirect)
if echo "$CLUSTERS_RESPONSE" | grep -qiE "<html|<!DOCTYPE"; then
    error "Received HTML instead of JSON from clusters API (HTTP $CLUSTERS_HTTP_CODE)"
    error "This usually indicates:"
    error "  1. Authentication failure (invalid/expired token)"
    error "  2. Endpoint redirect issue"
    error "  3. Wrong endpoint URL"
    log "Response preview: ${CLUSTERS_RESPONSE:0:300}"
    log ""
    log "Please verify:"
    log "  - ROX_ENDPOINT is correct: $ROX_ENDPOINT"
    log "  - ROX_API_TOKEN is valid (check with: curl -k -H \"Authorization: Bearer \$ROX_API_TOKEN\" \"$ROX_ENDPOINT/v1/metadata\")"
    exit 1
fi

# Validate JSON response
if ! echo "$CLUSTERS_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from clusters API (HTTP $CLUSTERS_HTTP_CODE)"
    log "Response: ${CLUSTERS_RESPONSE:0:200}"
    exit 1
fi

# Check HTTP status code
if [ "$CLUSTERS_HTTP_CODE" -lt 200 ] || [ "$CLUSTERS_HTTP_CODE" -ge 300 ]; then
    error "Clusters API returned HTTP $CLUSTERS_HTTP_CODE"
    log "Response: ${CLUSTERS_RESPONSE:0:200}"
    exit 1
fi

cluster_ids=$(echo "$CLUSTERS_RESPONSE" | jq -r '.clusters[]?.id // empty' 2>/dev/null)

if [ -z "$cluster_ids" ]; then
    error "No clusters found in response. Check cluster registration: oc get securedcluster -A"
    log "Response: ${CLUSTERS_RESPONSE:0:300}"
fi

if [ -n "$cluster_ids" ]; then
    log "Found clusters: $cluster_ids"
    
    # Trigger compliance runs for each cluster (legacy method)
    for cluster in $cluster_ids; do
        log "Triggering compliance run for cluster $cluster"
        
        set +e
        RUNS_FULL_RESPONSE=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runs" -X POST -d '{ "selection": { "cluster_id": "'"$cluster"'", "standard_id": "*" } }' 2>&1)
        RUNS_EXIT_CODE=$?
        set -e
        
        RUNS_HTTP_CODE=$(extract_http_code "$RUNS_FULL_RESPONSE")
        runs=$(extract_body "$RUNS_FULL_RESPONSE")
        
        if [ $RUNS_EXIT_CODE -ne 0 ]; then
            error "Failed to trigger compliance run for cluster $cluster (exit code: $RUNS_EXIT_CODE, HTTP $RUNS_HTTP_CODE). Response: ${runs:0:300}"
        fi
        
        if [ -z "$runs" ]; then
            error "Empty response when triggering compliance run for cluster $cluster (HTTP $RUNS_HTTP_CODE)"
        fi
        
        # Check if response is HTML
        if echo "$runs" | grep -qiE "<html|<!DOCTYPE"; then
            error "Received HTML instead of JSON when triggering compliance run for cluster $cluster (HTTP $RUNS_HTTP_CODE). Check authentication. Response: ${runs:0:300}"
        fi
        
        # Validate JSON response
        if ! echo "$runs" | jq . >/dev/null 2>&1; then
            error "Invalid JSON response when triggering compliance run for cluster $cluster (HTTP $RUNS_HTTP_CODE). Response: ${runs:0:300}"
        fi
        
        # Check HTTP status code
        if [ "$RUNS_HTTP_CODE" -lt 200 ] || [ "$RUNS_HTTP_CODE" -ge 300 ]; then
            error "Compliance run trigger returned HTTP $RUNS_HTTP_CODE for cluster $cluster. Response: ${runs:0:300}"
        fi
        
        run_ids=$(echo "$runs" | jq -r '.startedRuns[]?.id // empty' 2>/dev/null)
        num_runs=$(echo "$runs" | jq '.startedRuns | length // 0' 2>/dev/null)
        
        if [ "$num_runs" -eq 0 ] || [ -z "$run_ids" ]; then
            error "No compliance runs started for cluster $cluster. Response: ${runs:0:300}"
        fi
        
        log "Started $num_runs compliance runs for cluster $cluster"
        
        # Monitor compliance run completion
        while true; do
            size="$num_runs"
            for run_id in $run_ids; do
                RUN_STATUS_FULL_RESPONSE=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runstatuses" --data-urlencode "run_ids=$run_id" 2>&1)
                RUN_STATUS_BODY=$(extract_body "$RUN_STATUS_FULL_RESPONSE")
                
                if [ -z "$RUN_STATUS_BODY" ]; then
                    warning "Empty response when checking status for run $run_id, continuing..."
                    continue
                fi
                
                if ! echo "$RUN_STATUS_BODY" | jq . >/dev/null 2>&1; then
                    warning "Invalid JSON response when checking status for run $run_id, continuing..."
                    continue
                fi
                
                run_status=$(echo "$RUN_STATUS_BODY" | jq -r '.runs[0] // empty')
                
                if [ -z "$run_status" ] || [ "$run_status" = "null" ]; then
                    warning "Could not get status for run $run_id, continuing..."
                    continue
                fi
                
                run_state=$(echo "$run_status" | jq -r '.state // "UNKNOWN"' 2>/dev/null)
                standard=$(echo "$run_status" | jq -r '.standardId // "unknown"' 2>/dev/null)
                
                log "Run $run_id for cluster $cluster and standard $standard has state $run_state"
                
                if [[ "$run_state" == "FINISHED" ]]; then
                    size=$(( size - 1))
                elif [[ "$run_state" == "FAILED" ]]; then
                    warning "Run $run_id failed for cluster $cluster"
                    size=$(( size - 1))
                fi
            done
            
            if [[ "$size" == 0 ]]; then
                log "✓ Compliance scan for cluster $cluster has completed"
                break
            fi
            
            log "Waiting for compliance runs to complete... ($size remaining)"
            sleep 5
        done
    done
else
    error "No clusters found to trigger compliance scans. Check cluster registration: oc get securedcluster -A"
fi

    log "✓ Compliance scan trigger process completed successfully!"
