#!/bin/bash
# Compliance Management Scan Trigger Script
# Triggers a compliance management scan in Red Hat Advanced Cluster Security

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
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi

if [ -z "${ROX_ENDPOINT:-}" ]; then
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

# API endpoints
CLUSTERS_ENDPOINT="${ROX_ENDPOINT}/v1/clusters"
STANDARDS_ENDPOINT="${ROX_ENDPOINT}/v1/compliancemanagement/standards"
SCAN_ENDPOINT="${ROX_ENDPOINT}/v1/compliancemanagement/runs"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
    log "Making $description: $method $endpoint"
    
    local temp_file=""
    local curl_cmd="curl -k -s -w \"\n%{http_code}\" -X $method"
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $ROX_API_TOKEN\""
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
    
    if [ -n "$data" ]; then
        # For multi-line JSON, use a temporary file to avoid quoting issues
        if echo "$data" | grep -q $'\n'; then
            temp_file=$(mktemp)
            echo "$data" > "$temp_file"
            curl_cmd="$curl_cmd --data-binary @\"$temp_file\""
        else
            # Single-line data can use -d directly
            curl_cmd="$curl_cmd -d '$data'"
        fi
    fi
    
    curl_cmd="$curl_cmd \"$endpoint\""
    
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # Clean up temp file if used
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -ne 0 ]; then
        error "$description failed (curl exit code: $exit_code). Response: ${body:0:500}"
    fi
    
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        error "$description failed (HTTP $http_code). Response: ${body:0:500}"
    fi
    
    echo "$body"
}

# Fetch cluster ID - try to match by name first, then fall back to first connected cluster
log "Fetching cluster ID..."
CLUSTER_RESPONSE=$(make_api_call "GET" "$CLUSTERS_ENDPOINT" "" "Fetch clusters")

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Parse cluster response
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

# Try to find cluster by name "ads-cluster" first (set by script 01)
EXPECTED_CLUSTER_NAME="ads-cluster"
CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name == \"$EXPECTED_CLUSTER_NAME\") | .id" 2>/dev/null | head -1)

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
    log "Cluster '$EXPECTED_CLUSTER_NAME' not found, looking for any connected cluster..."
    # Fall back to first connected/healthy cluster
    CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | select(.healthStatus.overallHealthStatus == "HEALTHY" or .healthStatus.overallHealthStatus == "UNHEALTHY" or .healthStatus == null) | .id' 2>/dev/null | head -1)
    
    if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
        # Last resort: use first cluster
        CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[0].id' 2>/dev/null)
    fi
fi

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
    error "Failed to find a valid cluster ID. Available clusters: $(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | "\(.name): \(.id)"' 2>/dev/null | tr '\n' ' ' || echo "none")"
fi

# Verify cluster exists and get its name for logging
CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .name" 2>/dev/null | head -1)
CLUSTER_HEALTH=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .healthStatus.overallHealthStatus // \"UNKNOWN\"" 2>/dev/null | head -1)

if [ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "null" ]; then
    log "✓ Found cluster: $CLUSTER_NAME (ID: $CLUSTER_ID, Health: ${CLUSTER_HEALTH:-UNKNOWN})"
else
    log "✓ Using cluster ID: $CLUSTER_ID"
fi

# Fetch available compliance standards
log "Fetching available compliance standards..."
STANDARDS_RESPONSE=$(make_api_call "GET" "$STANDARDS_ENDPOINT" "" "Fetch compliance standards")

if [ -z "$STANDARDS_RESPONSE" ]; then
    error "Empty response from compliance standards API"
fi

# Parse compliance standards
if ! echo "$STANDARDS_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from compliance standards API. Response: ${STANDARDS_RESPONSE:0:300}"
fi

# Extract compliance standard IDs
STANDARD_IDS=$(echo "$STANDARDS_RESPONSE" | jq -r '.standards[]?.id // .[]?.id // empty' 2>/dev/null || echo "")

if [ -z "$STANDARD_IDS" ] || [ "$STANDARD_IDS" = "null" ]; then
    # Try alternative structure
    STANDARD_IDS=$(echo "$STANDARDS_RESPONSE" | jq -r '.[]?.id // empty' 2>/dev/null || echo "")
fi

if [ -z "$STANDARD_IDS" ]; then
    error "No compliance standards found. Response structure: $(echo "$STANDARDS_RESPONSE" | jq -c '.' 2>/dev/null | head -c 200 || echo "${STANDARDS_RESPONSE:0:200}")"
fi

# Get the first available standard ID
COMPLIANCE_STANDARD_ID=$(echo "$STANDARD_IDS" | head -n1)

if [ -z "$COMPLIANCE_STANDARD_ID" ] || [ "$COMPLIANCE_STANDARD_ID" = "null" ]; then
    error "Could not extract compliance standard ID from response"
fi

log "✓ Found compliance standard ID: $COMPLIANCE_STANDARD_ID"

# Display all available standards for reference
log "Available compliance standards:"
echo "$STANDARDS_RESPONSE" | jq -r '.standards[]? | "  - \(.name // .id): \(.id)"' 2>/dev/null || \
echo "$STANDARDS_RESPONSE" | jq -r '.[]? | "  - \(.name // .id): \(.id)"' 2>/dev/null || \
log "  (Unable to parse standard names)"

# Trigger compliance management scan
log "Triggering compliance management scan..."
log "Endpoint: $SCAN_ENDPOINT"
log "Using cluster ID: $CLUSTER_ID"
log "Using compliance standard ID: $COMPLIANCE_STANDARD_ID"

# Prepare scan request payload with selection object
SCAN_PAYLOAD=$(cat <<EOF
{
  "selection": {
    "clusterId": "$CLUSTER_ID",
    "standardId": "$COMPLIANCE_STANDARD_ID"
  }
}
EOF
)

# Make POST request to trigger the scan
SCAN_RESPONSE=$(make_api_call "POST" "$SCAN_ENDPOINT" "$SCAN_PAYLOAD" "Trigger compliance management scan")

log "✓ Compliance management scan triggered successfully"

# Parse and display response if available
if [ -n "$SCAN_RESPONSE" ]; then
    if echo "$SCAN_RESPONSE" | jq . >/dev/null 2>&1; then
        log "Scan response:"
        echo "$SCAN_RESPONSE" | jq '.' 2>/dev/null || echo "$SCAN_RESPONSE"
        
        # Try to extract scan ID or status if present
        SCAN_ID=$(echo "$SCAN_RESPONSE" | jq -r '.id // .scanId // .runId // empty' 2>/dev/null || echo "")
        if [ -n "$SCAN_ID" ] && [ "$SCAN_ID" != "null" ]; then
            log "✓ Scan ID: $SCAN_ID"
        fi
    else
        log "Response received: $SCAN_RESPONSE"
    fi
fi

log "========================================================="
log "Compliance Management Scan Trigger Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - Fetched cluster ID: $CLUSTER_ID ($CLUSTER_NAME)"
log "  - Fetched available compliance standards"
log "  - Compliance management scan triggered (POST $SCAN_ENDPOINT)"
log "  - Cluster ID used: $CLUSTER_ID"
log "  - Compliance standard ID used: $COMPLIANCE_STANDARD_ID"
log "  - Check RHACS UI for scan progress and results"

