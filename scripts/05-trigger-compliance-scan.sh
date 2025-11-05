#!/bin/bash
# Trigger Compliance Scan Script
# Triggers compliance scans for all clusters and monitors their completion

set -eo pipefail

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
    echo -e "${RED}[COMPLIANCE-SCAN]${NC} $1"
    exit 1
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
SCAN_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)

if [ $? -eq 0 ]; then
    SCAN_CONFIG_ID=$(echo "$SCAN_CONFIGS" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null)
    
    if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
        log "✓ Found 'acs-catch-all' scan configuration (ID: $SCAN_CONFIG_ID)"
        log "Triggering compliance scan using scan configuration..."
        
        RUN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data-raw "{\"scanConfigId\": \"$SCAN_CONFIG_ID\"}" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations/reports/run" 2>&1)
        
        if [ $? -eq 0 ]; then
            log "✓ Compliance scan triggered successfully using scan configuration"
            log "Scan will run according to the configured profiles and schedule"
            exit 0
        else
            warning "Failed to trigger scan using configuration, falling back to legacy method..."
        fi
    else
        log "Scan configuration 'acs-catch-all' not found, using legacy trigger method..."
    fi
else
    log "Could not fetch scan configurations, using legacy trigger method..."
fi

# Fallback: Get all cluster IDs and trigger legacy compliance runs
log "Fetching cluster IDs for legacy compliance trigger..."
cluster_ids=$(roxcurl "$ROX_ENDPOINT/v1/clusters" | jq -r .clusters[].id)

if [ -z "$cluster_ids" ]; then
    error "No clusters found or failed to fetch cluster IDs"
fi

log "Found clusters: $cluster_ids"

# Trigger compliance runs for each cluster (legacy method)
for cluster in $cluster_ids; do
    log "Triggering compliance run for cluster $cluster"
    
    runs=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runs" -X POST -d '{ "selection": { "cluster_id": "'"$cluster"'", "standard_id": "*" } }')
    
    if [ $? -ne 0 ]; then
        warning "Failed to trigger compliance run for cluster $cluster"
        continue
    fi
    
    run_ids=$(jq -r .startedRuns[].id <<< "$runs")
    num_runs=$(jq '.startedRuns | length' <<< "$runs")
    
    if [ "$num_runs" -eq 0 ]; then
        warning "No compliance runs started for cluster $cluster"
        continue
    fi
    
    log "Started $num_runs compliance runs for cluster $cluster"
    
    # Monitor compliance run completion
    while true; do
        size="$num_runs"
        for run_id in $run_ids; do
            run_status=$(roxcurl "$ROX_ENDPOINT/v1/compliancemanagement/runstatuses" --data-urlencode "run_ids=$run_id" | jq -r .runs[0])
            run_state=$(jq -r .state <<< "$run_status")
            standard=$(jq -r .standardId <<< "$run_status")
            
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

log "✓ All compliance scans completed successfully!"
