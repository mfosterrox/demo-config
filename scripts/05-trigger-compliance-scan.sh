#!/bin/bash
# Trigger Compliance Scan Script
# Triggers compliance scans for all clusters and monitors their completion

set -eo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[COMPLIANCE-SCAN]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-SCAN]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-SCAN]${NC} $1"
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
fi

if [[ -z "$ROX_ENDPOINT" ]]; then
    error "ROX_ENDPOINT needs to be set"
fi

# Ensure jq is installed
if [ ! -x "$(which jq)" ]; then
    warning "jq not found, installing..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y jq
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    else
        error "jq is required for this script to work correctly"
    fi
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

log "Starting compliance scan trigger process..."

# Function to make authenticated API calls
function roxcurl() {
    curl -sk -H "Authorization: Bearer $ROX_API_TOKEN" "$@"
}

# Try to trigger using scan configuration first (preferred method)
log "Checking for 'acs-catch-all' scan configuration..."
SCAN_CONFIGS=""
SCAN_CONFIG_ERROR=""

# Temporarily disable exit on error for this section
set +e
SCAN_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
CURL_EXIT_CODE=$?
set -e

if [ $CURL_EXIT_CODE -eq 0 ] && [ -n "$SCAN_CONFIGS" ]; then
    # Check if response is valid JSON
    if echo "$SCAN_CONFIGS" | jq . >/dev/null 2>&1; then
        log "✓ Successfully fetched scan configurations"
        SCAN_CONFIG_ID=$(echo "$SCAN_CONFIGS" | jq -r '.configurations[]? | select(.scanName == "acs-catch-all") | .id' 2>/dev/null)
        
        if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ] && [ "$SCAN_CONFIG_ID" != "" ]; then
            log "✓ Found 'acs-catch-all' scan configuration (ID: $SCAN_CONFIG_ID)"
            log "Triggering compliance scan using scan configuration..."
            
            set +e
            RUN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
                -H "Authorization: Bearer $ROX_API_TOKEN" \
                -H "Content-Type: application/json" \
                --data-raw "{\"scanConfigId\": \"$SCAN_CONFIG_ID\"}" \
                "$ROX_ENDPOINT/v2/compliance/scan/configurations/reports/run" 2>&1)
            RUN_EXIT_CODE=$?
            set -e
            
            if [ $RUN_EXIT_CODE -eq 0 ]; then
                # Check if response indicates success
                if echo "$RUN_RESPONSE" | jq . >/dev/null 2>&1; then
                    log "✓ Compliance scan triggered successfully using scan configuration"
                    log "Scan will run according to the configured profiles and schedule"
                    exit 0
                else
                    warning "Scan trigger API returned non-JSON response, falling back to legacy method..."
                    log "Response: $RUN_RESPONSE"
                fi
            else
                warning "Failed to trigger scan using configuration (exit code: $RUN_EXIT_CODE), falling back to legacy method..."
                if [ -n "$RUN_RESPONSE" ]; then
                    log "Error response: $RUN_RESPONSE"
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
set +e
CLUSTERS_RESPONSE=$(roxcurl "$ROX_ENDPOINT/v1/clusters" 2>&1)
CLUSTERS_EXIT_CODE=$?
set -e

if [ $CLUSTERS_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch clusters (exit code: $CLUSTERS_EXIT_CODE)"
    log "Response: ${CLUSTERS_RESPONSE:0:200}"
    exit 1
fi

if [ -z "$CLUSTERS_RESPONSE" ]; then
    error "Empty response from clusters API"
    exit 1
fi

# Validate JSON response
if ! echo "$CLUSTERS_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from clusters API"
    log "Response: ${CLUSTERS_RESPONSE:0:200}"
    exit 1
fi

cluster_ids=$(echo "$CLUSTERS_RESPONSE" | jq -r '.clusters[]?.id // empty' 2>/dev/null)

if [ -z "$cluster_ids" ]; then
    warning "No clusters found in response"
    log "Response: ${CLUSTERS_RESPONSE:0:200}"
    log "Attempting to continue anyway..."
    cluster_ids=""
fi

if [ -n "$cluster_ids" ]; then
    log "Found clusters: $cluster_ids"
    
    # Trigger compliance runs for each cluster (legacy method)
    for cluster in $cluster_ids; do
        log "Triggering compliance run for cluster $cluster"
        
        set +e
        runs=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runs" -X POST -d '{ "selection": { "cluster_id": "'"$cluster"'", "standard_id": "*" } }' 2>&1)
        RUNS_EXIT_CODE=$?
        set -e
        
        if [ $RUNS_EXIT_CODE -ne 0 ]; then
            warning "Failed to trigger compliance run for cluster $cluster (exit code: $RUNS_EXIT_CODE)"
            if [ -n "$runs" ]; then
                log "Error response: ${runs:0:200}"
            fi
            continue
        fi
        
        if [ -z "$runs" ]; then
            warning "Empty response when triggering compliance run for cluster $cluster"
            continue
        fi
        
        # Validate JSON response
        if ! echo "$runs" | jq . >/dev/null 2>&1; then
            warning "Invalid JSON response when triggering compliance run for cluster $cluster"
            log "Response: ${runs:0:200}"
            continue
        fi
        
        run_ids=$(echo "$runs" | jq -r '.startedRuns[]?.id // empty' 2>/dev/null)
        num_runs=$(echo "$runs" | jq '.startedRuns | length // 0' 2>/dev/null)
        
        if [ "$num_runs" -eq 0 ] || [ -z "$run_ids" ]; then
            warning "No compliance runs started for cluster $cluster"
            log "Response: ${runs:0:200}"
            continue
        fi
        
        log "Started $num_runs compliance runs for cluster $cluster"
        
        # Monitor compliance run completion
        while true; do
            size="$num_runs"
            for run_id in $run_ids; do
                set +e
                run_status=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runstatuses" --data-urlencode "run_ids=$run_id" 2>&1 | jq -r '.runs[0] // empty' 2>/dev/null)
                set -e
                
                if [ -z "$run_status" ] || [ "$run_status" = "null" ]; then
                    warning "Could not get status for run $run_id"
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
    warning "No clusters found to trigger compliance scans"
    log "This may be normal if clusters are still being registered or if the API endpoint is not fully available"
fi

if [ "$SCRIPT_FAILED" = true ]; then
    warning "Compliance scan trigger completed with errors. Review log output for details."
    exit 1
else
    log "✓ Compliance scan trigger process completed successfully!"
fi
